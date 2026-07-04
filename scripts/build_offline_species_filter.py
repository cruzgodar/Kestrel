#!/usr/bin/env python3
"""
Precompute the "birds by location and time of year" table offline.

The app filters detections to species plausible at the user's location and the
current week by running the bundled BirdNET location model
(`Kestrel/Models/birdnet_data_model.onnx`) on `(latitude, longitude, week)`.
That needs a location fix at listen-start; this script runs the *same* model
ahead of time over a global lat/lon grid for all 48 BirdNET weeks and bakes the
result into a compact data file the app can fall back on when it can't compute a
fresh filter (no connection / no fix / model failure).

The output is the canonical source — the model — sampled on a grid, so it stays
consistent with the live path (same model, same `0.03` threshold, same label
order / indices used by `SpeciesCatalog` and `SpeciesRangeFilter`).

Output (written next to the model, under Kestrel/Models/):
    offline_species_filter.bin   — gzipped binary table (see FORMAT below)

Bundle that .bin with the app and look it up by nearest grid cell + week. See
`OfflineSpeciesFilter` on the Swift side (added alongside this script) for the
reader; it changes no behavior unless the file is present in the bundle.

FORMAT, little-endian. A plaintext header followed by a raw-DEFLATE-compressed
body (raw DEFLATE — no zlib/gzip wrapper — so Apple's `Compression` framework
decodes it directly with `COMPRESSION_ZLIB`; no third-party dep on the app side):

    HEADER (uncompressed):
    magic           4 bytes  b"KOSF"
    version         uint8    = 2
    threshold       float32  (e.g. 0.03)
    species_count   uint32   (must match the labels file: 6522)
    lat_min         float32
    lat_max         float32
    lon_min         float32
    lon_max         float32
    step            float32  (grid resolution in degrees)
    lat_cells       uint16
    lon_cells       uint16
    weeks           uint8    (= 48)
    body_raw_len    uint32   (length of the body AFTER inflation)

    BODY (raw DEFLATE; once inflated, for each cell row-major — lat outer, lon
    inner — for each week 1..weeks):
    count           uint16   number of allowed species indices
    indices         count × varint, delta-encoded (sorted ascending)

Cell (i, j) covers the point lat = lat_min + i*step, lon = lon_min + j*step,
i.e. grid *samples*, and the reader snaps a query to the nearest sample.

Usage:
    pip install onnxruntime numpy
    python3 scripts/build_offline_species_filter.py                 # 3° grid (default)
    python3 scripts/build_offline_species_filter.py --step 1.5      # finer, larger file
    python3 scripts/build_offline_species_filter.py --step 5 --quick # coarse smoke test
"""

from __future__ import annotations

import argparse
import struct
import sys
import time
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = REPO_ROOT / "Kestrel" / "Models"
MODEL_PATH = MODELS_DIR / "birdnet_data_model.onnx"
LABELS_PATH = MODELS_DIR / "BirdNET_GLOBAL_6K_V2.4_Labels.txt"
OUTPUT_PATH = MODELS_DIR / "offline_species_filter.bin"

# Mirror SpeciesRangeFilter.threshold / speciesCount exactly.
DEFAULT_THRESHOLD = 0.03
EXPECTED_SPECIES = 6522
WEEKS = 48

MAGIC = b"KOSF"
VERSION = 2


def load_labels() -> list[str]:
    lines = LABELS_PATH.read_text(encoding="utf-8").splitlines()
    labels = [ln.strip() for ln in lines if ln.strip()]
    if len(labels) != EXPECTED_SPECIES:
        print(
            f"warning: labels file has {len(labels)} entries, expected "
            f"{EXPECTED_SPECIES}. Proceeding with {len(labels)}.",
            file=sys.stderr,
        )
    return labels


def build_session(threads: int):
    try:
        import onnxruntime as ort  # noqa: F401
    except ImportError:
        sys.exit("onnxruntime not installed. Run: pip install onnxruntime numpy")
    import onnxruntime as ort

    opts = ort.SessionOptions()
    opts.intra_op_num_threads = threads
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    sess = ort.InferenceSession(str(MODEL_PATH), sess_options=opts,
                                providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    out = sess.get_outputs()[0]
    return sess, inp.name, out.name


def encode_varint(buf: bytearray, value: int) -> None:
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            buf.append(byte | 0x80)
        else:
            buf.append(byte)
            return


def main() -> None:
    p = argparse.ArgumentParser(description="Precompute offline species-by-location-by-week table.")
    p.add_argument("--step", type=float, default=3.0,
                   help="Grid resolution in degrees (default 3.0; smaller = finer & larger file).")
    p.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                   help="Probability threshold for inclusion (default 0.03, matching the app).")
    p.add_argument("--lat-min", type=float, default=-90.0)
    p.add_argument("--lat-max", type=float, default=90.0)
    p.add_argument("--lon-min", type=float, default=-180.0)
    p.add_argument("--lon-max", type=float, default=180.0)
    p.add_argument("--threads", type=int, default=0,
                   help="onnxruntime intra-op threads (0 = library default).")
    p.add_argument("--quick", action="store_true",
                   help="Only compute week 25 (mid-year) for a fast smoke test; still writes 48 weeks (copied).")
    p.add_argument("--output", type=Path, default=OUTPUT_PATH)
    args = p.parse_args()

    if not MODEL_PATH.exists():
        sys.exit(f"model not found: {MODEL_PATH}")
    if not LABELS_PATH.exists():
        sys.exit(f"labels not found: {LABELS_PATH}")

    import numpy as np

    labels = load_labels()
    species_count = len(labels)
    sess, in_name, out_name = build_session(args.threads or 1)

    step = args.step
    lats = np.arange(args.lat_min, args.lat_max + 1e-9, step, dtype=np.float32)
    lons = np.arange(args.lon_min, args.lon_max + 1e-9, step, dtype=np.float32)
    lat_cells = len(lats)
    lon_cells = len(lons)
    weeks = list(range(1, WEEKS + 1))
    compute_weeks = [25] if args.quick else weeks

    total_cells = lat_cells * lon_cells
    print(f"grid: {lat_cells} lat × {lon_cells} lon = {total_cells} cells, "
          f"{len(compute_weeks)} week(s), threshold {args.threshold}")

    # Output body: per cell (lat outer, lon inner), per week 1..48, a count +
    # delta-varint species indices.
    body = bytearray()
    threshold = np.float32(args.threshold)
    start = time.time()

    # Batch one cell's weeks together (small, cache-friendly); for finer grids
    # this is plenty fast and keeps memory flat.
    for i, lat in enumerate(lats):
        for j, lon in enumerate(lons):
            # Inference for the weeks we actually compute.
            batch = np.array([[lat, lon, float(w)] for w in compute_weeks], dtype=np.float32)
            probs = sess.run([out_name], {in_name: batch})[0]  # (len(compute_weeks), species_count)

            if args.quick:
                # Reuse the single computed week for every week slot.
                allowed_by_week = {w: probs[0] for w in weeks}
            else:
                allowed_by_week = {w: probs[k] for k, w in enumerate(compute_weeks)}

            for w in weeks:
                row = allowed_by_week[w]
                idxs = np.nonzero(row >= threshold)[0]
                body += struct.pack("<H", len(idxs))
                prev = 0
                for idx in idxs:
                    encode_varint(body, int(idx) - prev)
                    prev = int(idx)

        done = (i + 1) * lon_cells
        elapsed = time.time() - start
        rate = done / elapsed if elapsed else 0
        eta = (total_cells - done) / rate if rate else 0
        print(f"\r  {done}/{total_cells} cells  ({rate:.0f}/s, ETA {eta:.0f}s)   ",
              end="", file=sys.stderr, flush=True)
    print(file=sys.stderr)

    # Raw DEFLATE (wbits=-15): no zlib/gzip wrapper, so Apple's Compression
    # framework decodes it directly with COMPRESSION_ZLIB.
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = compressor.compress(bytes(body)) + compressor.flush()

    header = bytearray()
    header += MAGIC
    header += struct.pack("<B", VERSION)
    header += struct.pack("<f", float(args.threshold))
    header += struct.pack("<I", species_count)
    header += struct.pack("<f", float(lats[0]))
    header += struct.pack("<f", float(lats[-1]))
    header += struct.pack("<f", float(lons[0]))
    header += struct.pack("<f", float(lons[-1]))
    header += struct.pack("<f", float(step))
    header += struct.pack("<H", lat_cells)
    header += struct.pack("<H", lon_cells)
    header += struct.pack("<B", WEEKS)
    header += struct.pack("<I", len(body))  # raw body length, for inflation

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(bytes(header) + compressed)

    size = args.output.stat().st_size
    print(f"wrote {args.output} ({size / 1e6:.1f} MB on disk, {len(body) / 1e6:.1f} MB raw body) "
          f"in {time.time() - start:.0f}s")
    if args.quick:
        print("note: --quick reused week 25 for all weeks; rerun without --quick for the real table.")


if __name__ == "__main__":
    main()
