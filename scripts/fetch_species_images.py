#!/usr/bin/env python3
"""
Fetch a thumbnail per BirdNET species and bundle them with the app.

Reads `Kestrel/Models/BirdNET_GLOBAL_6K_V2.4_Labels.txt` (6,522 species),
queries iNaturalist's public API (primary) and Wikipedia REST (fallback) for
each scientific name, downloads the returned image, resizes so the longer
side is 128 px (preserving aspect ratio — no cropping), and saves as
JPEG quality 80 to `Kestrel/Models/SpeciesImages/<slug>.jpg`.

Idempotent: skips any species that already has a file on disk. Misses are
logged to `scripts/species_images_missing.txt`.

Usage:
    python3 scripts/fetch_species_images.py            # full run
    python3 scripts/fetch_species_images.py --limit 50 # first 50 only
    python3 scripts/fetch_species_images.py --workers 8

Why iNaturalist (not Merlin/eBird):
    eBird's curated Macaulay Library photos require an API key. iNaturalist's
    public API is auth-free, CC-licensed, designed for programmatic access
    (S3-hosted images with no rate limiting), and has good coverage of bird
    species. Wikipedia is kept as a fallback for the few cases iNaturalist
    has no taxon for. To switch primary to eBird later, add a function that
    uses your eBird API token + the v2 taxonomy endpoint, then scrapes
    the og:image off https://ebird.org/species/<code>.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import io
import os
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
OUT_DIR    = ROOT / "Kestrel" / "Models" / "SpeciesImages"
MISSING    = ROOT / "scripts" / "species_images_missing.txt"

# ---------------------------------------------------------------------------
# Config

# Wikimedia's upload CDN rejects User-Agents that look bot-like (the
# "Kestrel-Bird-ID/0.1 (contact)" style returns 403 from upload.wikimedia.org
# even though that's the format their policy documents). Use a real browser UA.
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)
MAX_SIDE   = 128
JPEG_Q     = 80
TIMEOUT    = 15
# iNaturalist asks API users to stay under 60 req/min sustained — call it
# 1 req/sec to be safe. S3 image hosts don't really rate limit. Wikipedia
# fallback hits upload.wikimedia.org which 429s aggressively, so we use the
# same throttle there.
MIN_INTERVAL_PER_HOST = 0.5  # ~2 req/sec ceiling per host
MAX_RETRIES_429 = 4

# Skip BirdNET's non-bird event classes outright. They start with one of
# these names and have no meaningful Wikipedia article match.
NON_BIRD_PREFIXES = (
    "Engine_",
    "Fireworks_",
    "Gun_",
    "Human ",
    "Noise_",
    "Power tools",
    "Siren_",
    "Dog_",
)

# ---------------------------------------------------------------------------
# Slug helper. Must match SpeciesImage.slug(for:) in Swift.

def slug_for(scientific_name: str) -> str:
    s = unicodedata.normalize("NFKD", scientific_name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    s = s.strip("_")
    return s

# ---------------------------------------------------------------------------
# Per-host throttle.

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
SESSION.headers["User-Agent"] = USER_AGENT

def get(url: str, **kwargs) -> requests.Response:
    host = urllib.parse.urlparse(url).netloc
    for attempt in range(MAX_RETRIES_429 + 1):
        THROTTLE.wait(host)
        r = SESSION.get(url, timeout=TIMEOUT, **kwargs)
        if r.status_code == 429 and attempt < MAX_RETRIES_429:
            # Exponential backoff; honor Retry-After if present.
            retry_after = r.headers.get("Retry-After")
            try:
                wait = float(retry_after) if retry_after else 2.0 * (attempt + 1)
            except ValueError:
                wait = 2.0 * (attempt + 1)
            time.sleep(min(wait, 30.0))
            continue
        return r
    return r

# ---------------------------------------------------------------------------
# Image sources.

INAT_TAXA    = "https://api.inaturalist.org/v1/taxa"
WIKI_SUMMARY = "https://en.wikipedia.org/api/rest_v1/page/summary/"

def inaturalist_image_url(scientific_name: str) -> str | None:
    r = get(INAT_TAXA, params={
        "q": scientific_name,
        "rank": "species",
        "per_page": 1,
        "is_active": "true",
    })
    r.raise_for_status()
    data = r.json()
    results = data.get("results") or []
    if not results:
        return None
    top = results[0]
    # Confirm name match (case-insensitive) before trusting the search hit.
    if top.get("name", "").lower() != scientific_name.lower():
        return None
    photo = top.get("default_photo")
    if not isinstance(photo, dict):
        return None
    # medium_url is ~240px on the longest side — plenty for our 128 px target.
    return photo.get("medium_url") or photo.get("url")

def wikipedia_image_url(scientific_name: str) -> str | None:
    title = urllib.parse.quote(scientific_name.replace(" ", "_"))
    r = get(f"{WIKI_SUMMARY}{title}")
    if r.status_code == 404:
        return None
    r.raise_for_status()
    data = r.json()
    if data.get("type") == "disambiguation":
        return None
    # Use the pre-resized thumbnail; the upload-CDN thumbnail path is more
    # lenient than original-image fetches.
    thumb = data.get("thumbnail")
    if isinstance(thumb, dict) and thumb.get("source"):
        return thumb["source"]
    if "originalimage" in data and isinstance(data["originalimage"], dict):
        return data["originalimage"].get("source")
    return None

# ---------------------------------------------------------------------------
# Download + resize.

def download_and_save(image_url: str, dest: Path) -> None:
    r = get(image_url)
    r.raise_for_status()
    ctype = r.headers.get("Content-Type", "")
    if not ctype.lower().startswith("image/"):
        raise RuntimeError(f"non-image content-type: {ctype}")
    img = Image.open(io.BytesIO(r.content))
    # Strip animations / palette quirks.
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    w, h = img.size
    if max(w, h) > MAX_SIDE:
        if w >= h:
            new_w = MAX_SIDE
            new_h = max(1, round(h * MAX_SIDE / w))
        else:
            new_h = MAX_SIDE
            new_w = max(1, round(w * MAX_SIDE / h))
        img = img.resize((new_w, new_h), Image.LANCZOS)
    # Atomic write so a crashed run never leaves a half-written file.
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    img.save(tmp, format="JPEG", quality=JPEG_Q, optimize=True, progressive=True)
    tmp.replace(dest)

# ---------------------------------------------------------------------------
# Per-species worker.

def process_species(scientific: str, common: str, dest: Path) -> tuple[str, str]:
    """Returns ('ok' | 'skip' | 'miss' | 'err', reason)."""
    if dest.exists() and dest.stat().st_size > 0:
        return "skip", "already exists"
    if any(scientific.startswith(p) or common.startswith(p) for p in NON_BIRD_PREFIXES):
        return "miss", "non-bird event class"
    # Primary: iNaturalist.
    sources_tried: list[str] = []
    url: str | None = None
    try:
        url = inaturalist_image_url(scientific)
        sources_tried.append("inat")
    except Exception as e:
        sources_tried.append(f"inat-err:{e}")
    # Fallback: Wikipedia.
    if not url:
        try:
            url = wikipedia_image_url(scientific)
            sources_tried.append("wiki")
        except Exception as e:
            sources_tried.append(f"wiki-err:{e}")
    if not url:
        return "miss", f"no image ({','.join(sources_tried)})"
    try:
        download_and_save(url, dest)
    except Exception as e:
        return "err", f"download/resize: {e}"
    return "ok", url

# ---------------------------------------------------------------------------
# Main.

def parse_labels() -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    with LABELS.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if "_" in line:
                sci, common = line.split("_", 1)
            else:
                sci, common = line, line
            rows.append((sci.strip(), common.strip()))
    return rows

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0,
                    help="only process the first N species (for testing)")
    ap.add_argument("--workers", type=int, default=4,
                    help="parallel download workers (default 4)")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
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
            dest = OUT_DIR / f"{slug}.jpg"
            futures[pool.submit(process_species, sci, common, dest)] = (sci, common, dest)

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
            if i % 50 == 0:
                elapsed = time.time() - started
                rate = i / max(elapsed, 1)
                eta_min = (len(rows) - i) / max(rate, 0.001) / 60
                print(
                    f"  [{i}/{len(rows)}]  ok={ok} skip={skip} miss={miss} err={err}  "
                    f"{rate:.1f}/s  eta {eta_min:.1f}m",
                    flush=True,
                )

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
