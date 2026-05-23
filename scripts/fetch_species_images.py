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
SMALL_DIR  = ROOT / "Kestrel" / "Models" / "SpeciesImages"
MANUAL_DIR = ROOT / "scripts" / "manual"
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

MAX_SIDE       = 768   # large bundled variant
SMALL_MAX_SIDE = 128   # small bundled variant (row thumbnails)
JPEG_Q         = 80
TIMEOUT        = 20

# Per-host minimum interval between requests. Conservative; user explicitly
# wants "slow enough not to get throttled". Adjust upward if you start
# seeing 429s in the audit log.
MIN_INTERVAL_PER_HOST = 2.0
MAX_RETRIES_429 = 5

EBIRD_TAXONOMY_URL = "https://api.ebird.org/v2/ref/taxonomy/ebird?fmt=csv"
EBIRD_SPECIES_BASE = "https://ebird.org/species"

# Non-bird BirdNET event classes that have no species page anywhere.
# These appear in the label file as e.g. "Engine_Engine"; after the underscore
# split, both sci and common become just "Engine". Match by equality OR by the
# original "_" prefix form so either parse style is caught.
NON_BIRD_EVENT_CLASSES = frozenset({
    "Engine", "Environmental", "Fireworks", "Gun", "Human",
    "Human non-vocal", "Human vocal", "Human whistle",
    "Noise", "Power tools", "Siren", "Dog",
})

# BirdNET also ships labels for amphibians, insects, and mammals — there's no
# eBird page for any of these. Match on common-name substrings (handles both
# the slug-side label and the parsed common name). Kept here so they don't
# pollute the missing-images audit log as "not in eBird taxonomy".
NON_BIRD_COMMON_NAME_TERMS = (
    "Frog", "Toad", "Treefrog", "Tree Frog", "Peeper", "Spadefoot",
    "Cricket", "Katydid", "Conehead", "Trig", "Shieldback", "Angle-wing",
    "Bullfrog",
    "Squirrel", "Chipmunk", "Wolf", "Coyote", "Deer", "Monkey",
    "Honey Bee", "Bumble Bee",
)

# BirdNET sci-name → eBird sci name. Manual overrides for taxonomic mismatches
# where neither the scientific name, common name, nor unique-epithet fallback
# can resolve the bird (typically recent splits or lumps where multiple eBird
# species share the legacy banding code and there's no clean automated pick).
# Keep this list short and only add entries that are visually clear "this image
# is the closest available match" calls.
EBIRD_SCI_OVERRIDES: dict[str, str] = {
    # Cattle Egret was split in 2024 into Western (the cosmopolitan form most
    # BirdNET training audio represents) and Eastern Cattle-Egret.
    "Bubulcus ibis": "Ardea ibis",
    # Northern Goshawk was split into Eurasian (Holarctic, BirdNET's training
    # data is dominated by Eurasian recordings) and American Goshawk.
    "Accipiter gentilis": "Astur gentilis",
    # Hoary and Lesser Redpoll were lumped into Common Redpoll in 2024.
    "Acanthis hornemanni": "Acanthis flammea",
    "Acanthis cabaret":   "Acanthis flammea",
    # Cordilleran Flycatcher was lumped with Pacific-slope into Western Flycatcher.
    "Empidonax occidentalis": "Empidonax difficilis",
    # Lesser Sand-Plover was split; Mongolian (Siberian) is the form most often
    # labeled "Lesser Sand-Plover" in older training data.
    "Charadrius mongolus": "Anarhynchus mongolus",
    # Japanese Tit was lumped into "Asian Tit" (Parus cinereus).
    "Parus minor": "Parus cinereus",
    # Genus moves where family + epithet + common-name all confirm the match.
    "Cacomantis leucolophus":    "Caliechthrus leucolophus",   # White-crowned Cuckoo/Koel
    "Phylloscartes difficilis":  "Pogonotriccus difficilis",   # Serra do Mar Bristle-Tyrant
    "Trachyphonus purpuratus":   "Trachylaemus purpuratus",    # Eastern Yellow-billed Barbet
    "Vanellus cayanus":          "Hoploxypterus cayanus",      # Pied Plover (Pied Lapwing)
    "Dryotriorchis spectabilis": "Circaetus spectabilis",      # Congo Snake-Eagle
}

# BirdNET also labels non-avian animals whose genus is a dead giveaway (no
# eBird page exists). Filter at genus level so misses where BirdNET stores
# sci-as-common (e.g. "Gryllus assimilis_Gryllus assimilis") still get caught.
NON_AVIAN_GENERA = frozenset({
    # Crickets
    "Gryllus", "Miogryllus", "Allonemobius", "Anaxipha", "Cyrtoxipha",
    "Eunemobius", "Neonemobius", "Oecanthus", "Orocharis", "Phyllopalpus",
    "Acheta",
    # Katydids / coneheads
    "Amblycorypha", "Atlanticus", "Conocephalus", "Microcentrum",
    "Neoconocephalus", "Orchelimum", "Pterophylla", "Scudderia",
    # Frogs / toads
    "Acris", "Anaxyrus", "Dryophytes", "Eleutherodactylus", "Gastrophryne",
    "Hyliola", "Incilius", "Lithobates", "Pseudacris", "Scaphiopus", "Spea",
    "Hyla", "Rana", "Bufo",
    # Mammals
    "Alouatta", "Canis", "Odocoileus", "Sciurus", "Tamias", "Tamiasciurus",
    # Bees
    "Apis", "Bombus",
})

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

class Taxonomy:
    """Lookups from BirdNET label fields to an eBird species code.

    Strategies, tried in order:
      1. Manual override (`EBIRD_SCI_OVERRIDES`) — for known splits/lumps.
      2. `by_sci` — exact scientific-name match. Primary path.
      3. `by_common` — common-name fallback. Catches genus reassignments
         where the common name is unchanged ("Hairy Woodpecker" stayed put
         when AOS moved `Leuconotopicus villosus` → `Dryobates villosus`).
      4. `by_epithet_unique` — last-resort match by species epithet, but
         only when exactly one eBird species uses that epithet. Catches
         cases like BirdNET's `Accipiter gentilis` resolving to eBird's
         `Astur gentilis` ('gentilis' is unique in the taxonomy).
    """
    def __init__(
        self,
        by_sci: dict[str, str],
        by_common: dict[str, str],
        by_epithet_unique: dict[str, tuple[str, str]],
    ):
        self.by_sci = by_sci
        self.by_common = by_common
        # epithet → (species_code, common_name) so we can sanity-check the
        # match before accepting it (see lookup).
        self.by_epithet_unique = by_epithet_unique

    def lookup(self, scientific: str, common: str) -> tuple[str | None, str | None]:
        """Returns (code, source) where source ∈ {"override","sci","common","epithet",None}."""
        # Override: a BirdNET sci-name → eBird sci-name remap. Look the
        # remapped name up via by_sci so we still use the live taxonomy code.
        if override := EBIRD_SCI_OVERRIDES.get(scientific):
            if code := self.by_sci.get(override.lower()):
                return code, "override"
        if code := self.by_sci.get(scientific.lower()):
            return code, "sci"
        if code := self.by_common.get(common.lower()):
            return code, "common"
        words = scientific.split()
        if len(words) >= 2:
            hit = self.by_epithet_unique.get(words[1].lower())
            if hit and _common_names_overlap(common, hit[1]):
                return hit[0], "epithet"
        return None, None


# Adjectives/positional words that are too generic to count as evidence two
# common names refer to the same bird. "Northern Goshawk" vs "Northern Cardinal"
# overlap on "Northern" only — not a match.
_COMMON_NAME_FILLERS = frozenset({
    "northern", "southern", "eastern", "western", "great", "greater", "lesser",
    "common", "american", "european", "asian", "african", "old", "new", "world",
})

def _common_names_overlap(a: str, b: str) -> bool:
    """True if `a` and `b` share at least one substantive (>=4-letter, non-filler)
    word. Used to gate the epithet fallback so we don't match e.g. Puna
    Canastero (`Asthenes sclateri`) to Sclater's Monal (`Lophophorus sclateri`).
    """
    def words(s: str) -> set[str]:
        toks = re.split(r"[^a-zA-Z]+", s.lower())
        return {t for t in toks if len(t) >= 4 and t not in _COMMON_NAME_FILLERS}
    return bool(words(a) & words(b))

def load_taxonomy() -> Taxonomy:
    if not TAXONOMY.exists() or TAXONOMY.stat().st_size < 1000:
        print(f"Downloading eBird taxonomy CSV → {TAXONOMY}", flush=True)
        r = get(EBIRD_TAXONOMY_URL)
        r.raise_for_status()
        TAXONOMY.write_bytes(r.content)
    by_sci: dict[str, str] = {}
    by_common: dict[str, str] = {}
    # epithet → (code, common_name), tracking duplicates so we drop ambiguous ones.
    epithet_codes: dict[str, tuple[str, str]] = {}
    epithet_ambiguous: set[str] = set()
    with TAXONOMY.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            sci    = (row.get("SCIENTIFIC_NAME") or "").strip()
            common = (row.get("PRIMARY_COM_NAME") or row.get("COMMON_NAME") or "").strip()
            code   = (row.get("SPECIES_CODE") or "").strip()
            category = (row.get("CATEGORY") or "").strip()
            if not code:
                continue
            if sci:
                by_sci[sci.lower()] = code
            if common:
                # First entry wins. eBird's CSV is roughly taxonomic-ordered and
                # subspecies-group rows ("Hairy Woodpecker (Eastern)") follow the
                # species row, so the bare common name binds to the species code.
                by_common.setdefault(common.lower(), code)
            # Epithet uniqueness is only meaningful for full species rows —
            # subspecies/group rows reuse the parent's epithet.
            if category == "species" and sci:
                parts = sci.split()
                if len(parts) >= 2:
                    ep = parts[1].lower()
                    if ep in epithet_ambiguous:
                        pass
                    elif ep in epithet_codes:
                        epithet_ambiguous.add(ep)
                        del epithet_codes[ep]
                    else:
                        epithet_codes[ep] = (code, common)
    print(f"Loaded {len(by_sci)} species ({len(by_common)} common names, "
          f"{len(epithet_codes)} unique epithets) from eBird taxonomy", flush=True)
    return Taxonomy(by_sci, by_common, epithet_codes)

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
# Manual image conversion.
#
# `scripts/manual/<Common Name>.jpeg|.jpg|.png` is the drop folder for species
# eBird won't (or can't) serve us — typically obscure regional birds, BirdNET
# event classes we deliberately handle, or species BirdNET itself doesn't ship
# (e.g. Pelagic Cormorant) but the user wants in their life list with an image.
#
# Each file is keyed by common name. We resolve the common name to a scientific
# name (BirdNET label first, then eBird taxonomy as fallback), derive the slug
# the rest of the app uses, and write resized JPEGs to both bundled folders.

def _resize_to(img: Image.Image, max_side: int) -> Image.Image:
    w, h = img.size
    if max(w, h) <= max_side:
        return img
    if w >= h:
        new_w, new_h = max_side, max(1, round(h * max_side / w))
    else:
        new_w, new_h = max(1, round(w * max_side / h)), max_side
    return img.resize((new_w, new_h), Image.LANCZOS)

def _save_jpeg(img: Image.Image, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    img.save(tmp, format="JPEG", quality=JPEG_Q, optimize=True, progressive=True)
    tmp.replace(dest)

def _birdnet_common_to_sci() -> dict[str, str]:
    """Lowercased common name → BirdNET scientific name. First label wins."""
    out: dict[str, str] = {}
    for sci, common in parse_labels():
        out.setdefault(common.lower(), sci)
    return out

def _ebird_common_to_sci(taxonomy: Taxonomy | None) -> dict[str, str]:
    """Lowercased common name → eBird scientific name. Built lazily from the
    taxonomy CSV — separate from `Taxonomy.by_common` (which yields a species
    code) because the manual pipeline needs an sci-name to derive a slug."""
    if not TAXONOMY.exists():
        return {}
    out: dict[str, str] = {}
    with TAXONOMY.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if (row.get("CATEGORY") or "").strip() != "species":
                continue
            sci = (row.get("SCIENTIFIC_NAME") or "").strip()
            common = (row.get("PRIMARY_COM_NAME") or row.get("COMMON_NAME") or "").strip()
            if sci and common:
                out.setdefault(common.lower(), sci)
    return out

def process_manual_images(taxonomy: Taxonomy | None) -> tuple[int, int, list[str]]:
    """Converts every image in MANUAL_DIR to bundled small + large JPEGs.

    Returns `(written, skipped_existing, unresolved)`. Each file is matched
    by common name to a scientific name (BirdNET first, eBird fallback). We
    skip files whose `_large.jpg` is already in OUT_DIR, so running the
    script repeatedly only converts genuinely new drops.
    """
    if not MANUAL_DIR.is_dir():
        return 0, 0, []
    birdnet_by_common = _birdnet_common_to_sci()
    ebird_by_common = _ebird_common_to_sci(taxonomy)
    written = 0
    skipped = 0
    unresolved: list[str] = []
    for f in sorted(MANUAL_DIR.iterdir()):
        if f.suffix.lower() not in (".jpg", ".jpeg", ".png"):
            continue
        common = f.stem
        sci = (
            birdnet_by_common.get(common.lower())
            or ebird_by_common.get(common.lower())
        )
        if not sci:
            unresolved.append(common)
            continue
        slug = slug_for(sci)
        if not slug:
            unresolved.append(common)
            continue
        large_path = OUT_DIR / f"{slug}_large.jpg"
        small_path = SMALL_DIR / f"{slug}.jpg"
        if large_path.exists() and small_path.exists():
            skipped += 1
            continue
        try:
            img = Image.open(f)
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
        except Exception as e:
            print(f"  manual: could not open {f.name}: {e}", file=sys.stderr)
            unresolved.append(common)
            continue
        if not large_path.exists():
            _save_jpeg(_resize_to(img, MAX_SIDE), large_path)
        if not small_path.exists():
            _save_jpeg(_resize_to(img, SMALL_MAX_SIDE), small_path)
        print(f"  manual: {common} → {slug}")
        written += 1
    return written, skipped, unresolved

# ---------------------------------------------------------------------------
# Per-species pipeline.

def process_species(scientific: str, common: str, dest: Path,
                    taxonomy: Taxonomy) -> tuple[str, str]:
    if dest.exists() and dest.stat().st_size > 0:
        return "skip", "already exists"
    if scientific in NON_BIRD_EVENT_CLASSES or common in NON_BIRD_EVENT_CLASSES:
        return "nonbird", "non-bird event class"
    if any(term in common for term in NON_BIRD_COMMON_NAME_TERMS):
        return "nonbird", "non-avian class (no eBird page)"
    genus = scientific.split(" ", 1)[0]
    if genus in NON_AVIAN_GENERA:
        return "nonbird", "non-avian genus (no eBird page)"

    code, _ = taxonomy.lookup(scientific, common)
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
    SMALL_DIR.mkdir(parents=True, exist_ok=True)
    _load_cookies()

    taxonomy = load_taxonomy()

    # Manual drops first — these don't need network, and processing them up
    # front means the eBird pass below sees their `_large.jpg` and skips.
    m_written, m_skipped, m_unresolved = process_manual_images(taxonomy)
    if m_written or m_skipped or m_unresolved:
        print(
            f"Manual images: wrote {m_written}, skipped {m_skipped} already-present, "
            f"{len(m_unresolved)} unresolved",
            flush=True,
        )
        for name in m_unresolved:
            print(f"  unresolved manual: {name}", file=sys.stderr)

    rows = parse_labels()
    if args.limit > 0:
        rows = rows[: args.limit]

    # Pre-existing audit log keyed by slug. We carry forward any entry whose
    # species we don't attempt this run (e.g. --limit), so a partial run can't
    # silently drop misses recorded by a previous full run.
    prior_misses = load_missing_log()

    print(f"Processing {len(rows)} species → {OUT_DIR}", flush=True)
    started = time.time()
    ok = skip = miss = nonbird = err = 0
    # Slugs we actually attempted this run — used to decide which prior_misses
    # entries to overwrite vs. carry forward.
    attempted: set[str] = set()
    current_misses: dict[str, str] = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures: dict[concurrent.futures.Future, tuple[str, str, Path]] = {}
        for sci, common in rows:
            slug = slug_for(sci)
            if not slug:
                continue
            dest = OUT_DIR / f"{slug}_large.jpg"
            attempted.add(slug_for(sci))
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
            elif status == "nonbird":
                # Filtered, not a "miss" — these have no eBird page by design,
                # so they shouldn't end up in the audit log.
                nonbird += 1
            elif status == "miss":
                miss += 1
                current_misses[slug_for(sci)] = f"{slug_for(sci)}\t{sci}\t{common}\t{reason}"
            else:
                err += 1
                current_misses[slug_for(sci)] = f"{slug_for(sci)}\t{sci}\t{common}\tERROR: {reason}"
            if i % 25 == 0:
                elapsed = time.time() - started
                rate = i / max(elapsed, 1)
                eta_min = (len(rows) - i) / max(rate, 0.001) / 60
                print(
                    f"  [{i}/{len(rows)}]  ok={ok} skip={skip} miss={miss} "
                    f"nonbird={nonbird} err={err}  "
                    f"{rate:.2f}/s  eta {eta_min:.1f}m",
                    flush=True,
                )

    _save_cookies()

    print(
        f"\nDone in {(time.time() - started)/60:.1f}m.  "
        f"ok={ok} skip={skip} miss={miss} nonbird={nonbird} err={err}",
        flush=True,
    )

    # Merge: drop prior entries for slugs we attempted this run (they're either
    # newly successful or replaced by a fresher miss reason), keep the rest.
    merged: dict[str, str] = {
        slug: line for slug, line in prior_misses.items() if slug not in attempted
    }
    merged.update(current_misses)
    # Also drop any slug whose image file now exists on disk — covers the case
    # where a prior run was interrupted before the audit log got rewritten.
    merged = {
        slug: line for slug, line in merged.items()
        if not (OUT_DIR / f"{slug}_large.jpg").exists()
    }
    write_missing_log(merged)
    print(
        f"Audit log: {MISSING} ({len(merged)} entries; "
        f"{len(current_misses)} from this run, "
        f"{len(merged) - len(current_misses)} carried forward)",
        flush=True,
    )
    return 0

def load_missing_log() -> dict[str, str]:
    """Returns {slug: original_line} from the existing audit log, or empty."""
    if not MISSING.exists():
        return {}
    out: dict[str, str] = {}
    with MISSING.open() as f:
        first = True
        for line in f:
            line = line.rstrip("\n")
            if first:
                first = False
                if line.startswith("slug\t"):
                    continue
            if not line:
                continue
            parts = line.split("\t")
            slug = parts[0]
            # Older runs wrote `<slug>_large` (the file stem) into the slug
            # column; normalize so merge keys match the canonical slug.
            if slug.endswith("_large"):
                slug = slug[: -len("_large")]
                parts[0] = slug
                line = "\t".join(parts)
            if slug:
                out[slug] = line
    return out

def write_missing_log(entries: dict[str, str]) -> None:
    MISSING.parent.mkdir(parents=True, exist_ok=True)
    with MISSING.open("w") as f:
        f.write("slug\tscientific\tcommon\treason\n")
        for slug in sorted(entries):
            f.write(entries[slug] + "\n")

if __name__ == "__main__":
    sys.exit(main())
