#!/usr/bin/env python3
"""
Fetch a thumbnail per BirdNET species and bundle them with the app.

Source: eBird species pages (the Macaulay Library "featured photo" each
species page links via `og:image`). Same image Merlin uses. No fallback —
species without an eBird image are skipped and logged.

Personal-use only. Conservative rate limiting (~1 request per 2 seconds per
host, with backoff on 429) so we don't get kicked.

Usage:
    python3 scripts/fetch_species_images.py            # full run (~hours)
    python3 scripts/fetch_species_images.py --limit 50 # first 50 only
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import io
import re
import sys
import threading
import time
import unicodedata
import urllib.parse
from pathlib import Path

import requests
from PIL import Image

# ---------------------------------------------------------------------------
# Paths

ROOT       = Path(__file__).resolve().parents[1]
LABELS     = ROOT / "Kestrel" / "Models" / "BirdNET_GLOBAL_6K_V2.4_Labels.txt"
OUT_DIR    = ROOT / "Kestrel" / "Models" / "SpeciesImagesLarge"
MISSING    = ROOT / "scripts" / "species_images_missing.txt"
TAXONOMY   = ROOT / "scripts" / ".ebird_taxonomy.csv"
COOKIE_JAR = ROOT / "scripts" / ".ebird_cookies.txt"

# ---------------------------------------------------------------------------
# Config

# eBird's frontend is fronted by Akamai. It rate-limits aggressively when
# requests look bot-like. Browser-style UA + cookie persistence + slow pacing
# is the difference between "works" and "kicked after 30 species".
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)

MAX_SIDE   = 768
JPEG_Q     = 80
TIMEOUT    = 20

# Per-host minimum interval between requests. Conservative; user explicitly
# wants "slow enough not to get throttled". Adjust upward if you start
# seeing 429s in the audit log.
MIN_INTERVAL_PER_HOST = 2.0
MAX_RETRIES_429 = 5

EBIRD_TAXONOMY_URL = "https://api.ebird.org/v2/ref/taxonomy/ebird?fmt=csv"
EBIRD_SPECIES_BASE = "https://ebird.org/species"

# Non-bird BirdNET event classes that have no species page anywhere.
NON_BIRD_PREFIXES = (
    "Engine_", "Fireworks_", "Gun_", "Human ", "Noise_", "Power tools",
    "Siren_", "Dog_",
)

# ---------------------------------------------------------------------------
# Filename slug — must match SpeciesImage.slug(for:) in Swift.

def slug_for(scientific_name: str) -> str:
    s = unicodedata.normalize("NFKD", scientific_name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_")

# ---------------------------------------------------------------------------
# Per-host throttle + retry-aware GET.

class HostThrottle:
    def __init__(self, min_interval: float):
        self.min_interval = min_interval
        self._lock = threading.Lock()
        self._next_allowed: dict[str, float] = {}

    def wait(self, host: str) -> None:
        with self._lock:
            now = time.monotonic()
            target = self._next_allowed.get(host, 0.0)
            sleep_for = max(0.0, target - now)
            self._next_allowed[host] = max(now, target) + self.min_interval
        if sleep_for > 0:
            time.sleep(sleep_for)

THROTTLE = HostThrottle(MIN_INTERVAL_PER_HOST)
SESSION  = requests.Session()
SESSION.headers.update({
    "User-Agent": USER_AGENT,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
})

def _load_cookies() -> None:
    if not COOKIE_JAR.exists():
        return
    try:
        with COOKIE_JAR.open() as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                name, _, value = line.partition("=")
                if name and value:
                    SESSION.cookies.set(name, value)
    except Exception as e:
        print(f"warning: could not load cookie jar: {e}", file=sys.stderr)

def _save_cookies() -> None:
    try:
        COOKIE_JAR.parent.mkdir(parents=True, exist_ok=True)
        with COOKIE_JAR.open("w") as f:
            f.write("# eBird session cookies (regenerated each run)\n")
            for c in SESSION.cookies:
                f.write(f"{c.name}={c.value}\n")
    except Exception as e:
        print(f"warning: could not save cookie jar: {e}", file=sys.stderr)

def get(url: str, **kwargs) -> requests.Response:
    host = urllib.parse.urlparse(url).netloc
    for attempt in range(MAX_RETRIES_429 + 1):
        THROTTLE.wait(host)
        r = SESSION.get(url, timeout=TIMEOUT, allow_redirects=True, **kwargs)
        if r.status_code in (429, 503) and attempt < MAX_RETRIES_429:
            retry_after = r.headers.get("Retry-After")
            try:
                wait = float(retry_after) if retry_after else 5.0 * (attempt + 1)
            except ValueError:
                wait = 5.0 * (attempt + 1)
            print(f"  {host} returned {r.status_code}; backing off {wait:.0f}s",
                  file=sys.stderr, flush=True)
            time.sleep(min(wait, 60.0))
            continue
        return r
    return r

# ---------------------------------------------------------------------------
# eBird taxonomy: scientific name → species code.

def load_taxonomy() -> dict[str, str]:
    """Returns {scientific_name_lower: species_code}. Caches the CSV on disk."""
    if not TAXONOMY.exists() or TAXONOMY.stat().st_size < 1000:
        print(f"Downloading eBird taxonomy CSV → {TAXONOMY}", flush=True)
        r = get(EBIRD_TAXONOMY_URL)
        r.raise_for_status()
        TAXONOMY.write_bytes(r.content)
    mapping: dict[str, str] = {}
    with TAXONOMY.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            sci  = (row.get("SCIENTIFIC_NAME") or "").strip()
            code = (row.get("SPECIES_CODE") or "").strip()
            if sci and code:
                mapping[sci.lower()] = code
    print(f"Loaded {len(mapping)} species from eBird taxonomy", flush=True)
    return mapping

# ---------------------------------------------------------------------------
# Image source: eBird species page → og:image (Macaulay Library CDN).

OG_IMAGE_RE = re.compile(
    r'<meta\s+property="og:image"\s+content="([^"]+)"', re.IGNORECASE
)

def ebird_image_url(species_code: str) -> str | None:
    url = f"{EBIRD_SPECIES_BASE}/{species_code}"
    r = get(url)
    if r.status_code != 200:
        return None
    m = OG_IMAGE_RE.search(r.text)
    if not m:
        return None
    img = m.group(1)
    # Skip the generic "no photo" placeholder.
    if "placeholder" in img or img.endswith("/0"):
        return None
    return img

# ---------------------------------------------------------------------------
# Download + resize.

def download_and_save(image_url: str, dest: Path) -> None:
    r = get(image_url)
    r.raise_for_status()
    ctype = r.headers.get("Content-Type", "")
    if not ctype.lower().startswith("image/"):
        raise RuntimeError(f"non-image content-type: {ctype}")
    img = Image.open(io.BytesIO(r.content))
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    w, h = img.size
    if max(w, h) > MAX_SIDE:
        if w >= h:
            new_w, new_h = MAX_SIDE, max(1, round(h * MAX_SIDE / w))
        else:
            new_w, new_h = max(1, round(w * MAX_SIDE / h)), MAX_SIDE
        img = img.resize((new_w, new_h), Image.LANCZOS)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    img.save(tmp, format="JPEG", quality=JPEG_Q, optimize=True, progressive=True)
    tmp.replace(dest)

# ---------------------------------------------------------------------------
# Per-species pipeline.

def process_species(scientific: str, common: str, dest: Path,
                    taxonomy: dict[str, str]) -> tuple[str, str]:
    if dest.exists() and dest.stat().st_size > 0:
        return "skip", "already exists"
    if any(scientific.startswith(p) or common.startswith(p) for p in NON_BIRD_PREFIXES):
        return "miss", "non-bird event class"

    code = taxonomy.get(scientific.lower())
    if not code:
        return "miss", "not in eBird taxonomy"

    try:
        img_url = ebird_image_url(code)
    except Exception as e:
        return "err", f"ebird:{code} → {e}"
    if not img_url:
        return "miss", f"no og:image on eBird page (code={code})"

    try:
        download_and_save(img_url, dest)
    except Exception as e:
        return "err", f"{img_url} → {e}"
    return "ok", img_url

# ---------------------------------------------------------------------------
# Main.

def parse_labels() -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    with LABELS.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            sci, common = (line.split("_", 1) + [line])[:2]
            rows.append((sci.strip(), common.strip()))
    return rows

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--workers", type=int, default=2,
                    help="parallel workers (default 2; keep small to avoid 429)")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    _load_cookies()

    taxonomy = load_taxonomy()
    rows = parse_labels()
    if args.limit > 0:
        rows = rows[: args.limit]

    print(f"Processing {len(rows)} species → {OUT_DIR}", flush=True)
    started = time.time()
    ok = skip = miss = err = 0
    misses: list[str] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures: dict[concurrent.futures.Future, tuple[str, str, Path]] = {}
        for sci, common in rows:
            slug = slug_for(sci)
            if not slug:
                continue
            dest = OUT_DIR / f"{slug}_large.jpg"
            futures[pool.submit(process_species, sci, common, dest, taxonomy)] = \
                (sci, common, dest)

        for i, fut in enumerate(concurrent.futures.as_completed(futures), start=1):
            sci, common, dest = futures[fut]
            try:
                status, reason = fut.result()
            except Exception as e:
                status, reason = "err", str(e)
            if status == "ok":
                ok += 1
            elif status == "skip":
                skip += 1
            elif status == "miss":
                miss += 1
                misses.append(f"{dest.stem}\t{sci}\t{common}\t{reason}")
            else:
                err += 1
                misses.append(f"{dest.stem}\t{sci}\t{common}\tERROR: {reason}")
            if i % 25 == 0:
                elapsed = time.time() - started
                rate = i / max(elapsed, 1)
                eta_min = (len(rows) - i) / max(rate, 0.001) / 60
                print(
                    f"  [{i}/{len(rows)}]  ok={ok} skip={skip} miss={miss} err={err}  "
                    f"{rate:.2f}/s  eta {eta_min:.1f}m",
                    flush=True,
                )

    _save_cookies()

    print(
        f"\nDone in {(time.time() - started)/60:.1f}m.  "
        f"ok={ok} skip={skip} miss={miss} err={err}",
        flush=True,
    )

    MISSING.parent.mkdir(parents=True, exist_ok=True)
    with MISSING.open("w") as f:
        f.write("slug\tscientific\tcommon\treason\n")
        f.writelines(line + "\n" for line in misses)
    print(f"Audit log: {MISSING} ({len(misses)} entries)", flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
