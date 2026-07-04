#!/usr/bin/env python3
"""
PROTOTYPE — automated sourcing + selection of an openly-licensed photo per
species, to replace the Macaulay Library scrape (which isn't licensed for our
download-and-cache use).

The pipeline is a funnel, one species at a time:

    iNaturalist candidates  (CC-licensed, research grade, most-faved first)
        -> framing filter    (one bird, whole body, fills the frame)   [YOLO/ONNX]
        -> content + quality  (no nest/chick/in-hand/flight, sharp, clean)
             * two interchangeable judges, run side-by-side for comparison:
                 - CLIP zero-shot   (local, free)          [needs a torch venv]
                 - Claude VLM        (highest accuracy)     [needs ANTHROPIC_API_KEY]
        -> pick the best -> species_photos.json row (+ license/source/attribution)

This prototype validates *selection quality* on a small sample before committing
to a multi-hour full run over all ~6.4k BirdNET species. It writes a contact
sheet (out/contact_sheet.html) so you can eyeball picks vs. rejects, plus a
machine-readable out/results.json.

Every stage degrades gracefully: with no ML deps and no API key it still fetches
candidates and builds the contact sheet, so the plumbing is verifiable anywhere.

Env-native by design: uses only urllib + json from the stdlib for the fetch and
the Claude REST call, so it runs in the existing 3.14 venv with zero installs.
The optional framing stage uses onnxruntime + numpy (already in the venv) plus a
YOLOv8 ONNX model you point it at.

Usage:
    python3 scripts/fetch_open_images.py                 # sample species
    python3 scripts/fetch_open_images.py --limit 4       # first 4 of the sample
    ANTHROPIC_API_KEY=... python3 scripts/fetch_open_images.py   # + VLM judge
    KESTREL_YOLO_ONNX=yolov8n.onnx python3 scripts/fetch_open_images.py  # + framing

Config knobs are constants near the top.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Config

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "scripts" / "open_images_out"

# Licenses to accept. Per the plan: CC0 / BY / BY-SA, plus the NC variants
# (fine for a free app). ND variants are excluded — we re-encode/resize, which
# is arguably a derivative and ND forbids that. iNat's license codes are lower
# case with hyphens.
ACCEPT_LICENSES = ["cc0", "cc-by", "cc-by-sa", "cc-by-nc", "cc-by-nc-sa"]

CANDIDATES_PER_SPECIES = 24   # gathered from iNat, most-faved first
TOP_K_FOR_JUDGE = 5           # only the best-framed few go to the (costlier) judges

# iNat photo size to request in URLs. "large" ~1024px — enough for the judges
# and for the app's medium tier. (square/small/medium/large/original.)
INAT_IMG_SIZE = "large"

USER_AGENT = "KestrelImageResearch/0.1 (https://github.com/cruzgodar/Kestrel)"
INAT_MIN_INTERVAL = 1.1       # be polite; iNat asks <= 1 req/sec sustained

# COCO class index for "bird" (YOLOv8 default weights).
COCO_BIRD_CLASS = 14
# Keep candidates whose largest bird box fills this fraction band of the frame.
# Below -> distant/cluttered; ~1.0 while touching all edges -> extreme crop.
FILL_MIN, FILL_MAX = 0.32, 0.92

# Prototype sample: a mix of easy (great coverage) and striking/tricky species.
# The full run would read these from BirdNET_GLOBAL_6K_V2.4_Labels.txt instead.
SAMPLE_SPECIES = [
    "Cardinalis cardinalis",     # Northern Cardinal
    "Turdus migratorius",        # American Robin
    "Spinus tristis",            # American Goldfinch
    "Setophaga petechia",        # Yellow Warbler
    "Megaceryle alcyon",         # Belted Kingfisher
    "Selasphorus rufus",         # Rufous Hummingbird
    "Recurvirostra americana",   # American Avocet
    "Cistothorus palustris",     # Marsh Wren
    "Bubo bubo",                 # Eurasian Eagle-Owl
    "Pharomachrus mocinno",      # Resplendent Quetzal
]

# ---------------------------------------------------------------------------
# HTTP helpers (stdlib only)

_last_inat_call = 0.0


def _get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def _inat_get(path: str, params: dict) -> dict:
    """Rate-limited GET against the iNaturalist API."""
    global _last_inat_call
    wait = INAT_MIN_INTERVAL - (time.monotonic() - _last_inat_call)
    if wait > 0:
        time.sleep(wait)
    qs = urllib.parse.urlencode(params, doseq=True)
    _last_inat_call = time.monotonic()
    return _get_json(f"https://api.inaturalist.org/v1{path}?{qs}")


# ---------------------------------------------------------------------------
# Stage 0 — candidate gathering from iNaturalist

def resolve_taxon(name: str) -> int | None:
    """Scientific name -> iNat taxon id (species rank), or None."""
    data = _inat_get("/taxa", {"q": name, "rank": "species", "per_page": 1})
    results = data.get("results") or []
    return results[0]["id"] if results else None


def _photo_url(photo: dict) -> str | None:
    """Rewrite an iNat photo's square/url to the desired size."""
    url = photo.get("url")
    if not url:
        return None
    # iNat photo urls look like .../photos/<id>/square.jpg — swap the size word.
    for size in ("square", "small", "medium", "large", "original"):
        url = url.replace(f"/{size}.", f"/{INAT_IMG_SIZE}.")
    return url


def gather_candidates(taxon_id: int, n: int) -> list[dict]:
    """Most-faved research-grade CC photos for a taxon, deduped by photo id."""
    data = _inat_get("/observations", {
        "taxon_id": taxon_id,
        "photo_license": ACCEPT_LICENSES,
        "quality_grade": "research",
        "has": ["photos"],
        "order_by": "votes",       # faves
        "order": "desc",
        "per_page": max(n * 2, 40),  # over-fetch; we dedup + cap below
        "locale": "en",
    })
    out: list[dict] = []
    seen: set[int] = set()
    for obs in data.get("results", []):
        faves = obs.get("cached_votes_total") or obs.get("faves_count") or 0
        for photo in obs.get("photos", []):
            pid = photo.get("id")
            lic = (photo.get("license_code") or "").lower()
            if pid in seen or lic not in ACCEPT_LICENSES:
                continue
            url = _photo_url(photo)
            if not url:
                continue
            seen.add(pid)
            out.append({
                "photo_id": pid,
                "url": url,
                "license": lic,
                "attribution": photo.get("attribution", ""),
                "obs_id": obs.get("id"),
                "obs_url": f"https://www.inaturalist.org/observations/{obs.get('id')}",
                "faves": faves,
            })
            if len(out) >= n:
                return out
    return out


# ---------------------------------------------------------------------------
# Stage 1 — framing filter (optional; onnxruntime + a YOLOv8 ONNX model)

def _load_yolo():
    """Return (session, PIL, np) if a YOLO ONNX model + Pillow are available."""
    model_path = os.environ.get("KESTREL_YOLO_ONNX")
    if not model_path or not Path(model_path).exists():
        return None
    try:
        import numpy as np
        import onnxruntime as ort
        from PIL import Image  # noqa: F401
    except Exception as exc:  # pragma: no cover - env dependent
        print(f"  framing: deps unavailable ({exc}); skipping", file=sys.stderr)
        return None
    return ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])


def framing_score(session, url: str) -> dict | None:
    """
    Run YOLOv8 on the image and return framing metrics:
      fill      largest bird box area / image area
      n_birds   number of bird boxes over a confidence floor
      centered  1 - normalized distance of box center from frame center
      ok        passes the single-subject + fill-band gate
    Returns None if the image couldn't be fetched/decoded.
    """
    import io

    import numpy as np
    from PIL import Image

    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as resp:
            img = Image.open(io.BytesIO(resp.read())).convert("RGB")
    except Exception:
        return None

    W, H = img.size
    # Letterbox to 640x640.
    s = 640 / max(W, H)
    nw, nh = int(round(W * s)), int(round(H * s))
    canvas = Image.new("RGB", (640, 640), (114, 114, 114))
    canvas.paste(img.resize((nw, nh)), ((640 - nw) // 2, (640 - nh) // 2))
    x = np.asarray(canvas, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0

    out = session.run(None, {session.get_inputs()[0].name: x})[0]  # [1,84,8400]
    pred = out[0].T                                                 # [8400,84]
    scores = pred[:, 4:]
    cls = scores.argmax(1)
    conf = scores.max(1)
    m = (cls == COCO_BIRD_CLASS) & (conf > 0.25)
    boxes = pred[m, :4]        # cx,cy,w,h in letterboxed 640 space
    if boxes.shape[0] == 0:
        return {"fill": 0.0, "n_birds": 0, "centered": 0.0, "ok": False}

    areas = boxes[:, 2] * boxes[:, 3]
    i = int(areas.argmax())
    cx, cy, bw, bh = boxes[i]
    # Undo letterbox to original-image fraction.
    pad_x, pad_y = (640 - nw) / 2, (640 - nh) / 2
    fill = (bw * bh) / (nw * nh)
    ncx, ncy = (cx - pad_x) / nw, (cy - pad_y) / nh
    centered = 1.0 - float(np.hypot(ncx - 0.5, ncy - 0.5) / 0.707)
    n_birds = int(boxes.shape[0])
    ok = (n_birds == 1) and (FILL_MIN <= fill <= FILL_MAX)
    return {"fill": round(float(fill), 3), "n_birds": n_birds,
            "centered": round(centered, 3), "ok": ok}


# ---------------------------------------------------------------------------
# Stage 2a — CLIP judge (optional; needs a torch-capable venv with open_clip)

_CLIP_POS = "a clear full-body photo of a single perched bird filling the frame"
_CLIP_NEG = [
    "a bird nest with eggs", "a baby bird chick", "a bird held in a human hand",
    "a blurry bird in flight", "a distant bird in a wide landscape",
    "an extreme close-up of a bird's head",
]


def load_clip():
    try:
        import open_clip  # noqa: F401
        import torch  # noqa: F401
    except Exception:
        return None
    import open_clip
    import torch
    model, _, preprocess = open_clip.create_model_and_transforms(
        "ViT-B-32", pretrained="laion2b_s34b_b79k")
    tok = open_clip.get_tokenizer("ViT-B-32")
    text = tok([_CLIP_POS, *_CLIP_NEG])
    with torch.no_grad():
        tfeat = model.encode_text(text)
        tfeat /= tfeat.norm(dim=-1, keepdim=True)
    return {"model": model, "preprocess": preprocess, "tfeat": tfeat, "torch": torch}


def clip_score(clip, url: str) -> float | None:
    """Softmax prob mass on the positive prompt vs. the negative set (0..1)."""
    import io

    from PIL import Image
    torch = clip["torch"]
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as resp:
            img = Image.open(io.BytesIO(resp.read())).convert("RGB")
    except Exception:
        return None
    x = clip["preprocess"](img).unsqueeze(0)
    with torch.no_grad():
        ifeat = clip["model"].encode_image(x)
        ifeat /= ifeat.norm(dim=-1, keepdim=True)
        logits = (100.0 * ifeat @ clip["tfeat"].T).softmax(dim=-1)[0]
    return round(float(logits[0]), 3)  # prob on the positive prompt


# ---------------------------------------------------------------------------
# Stage 2b — Claude VLM judge (optional; needs ANTHROPIC_API_KEY)

VLM_MODEL = "claude-haiku-4-5-20251001"   # cheap tier; the full run is one-time
VLM_RUBRIC = (
    "You are grading a bird photo for use as a field-guide thumbnail. Ideal: a "
    "single adult bird, whole body visible, sharply in focus, filling most of "
    "the frame, on a clean uncluttered background. Reject nests, eggs, chicks/"
    "juveniles, birds in a human hand, dead/specimen birds, heavy motion blur, "
    "flight shots where the bird is tiny, and back-only/obscured views. "
    'Reply ONLY with compact JSON: {"score":0-10,"fills_frame":true/false,'
    '"single_adult":true/false,"clean_background":true/false,"issues":["..."]}'
)


def vlm_score(url: str) -> dict | None:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    body = json.dumps({
        "model": VLM_MODEL,
        "max_tokens": 200,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "url", "url": url}},
                {"type": "text", "text": VLM_RUBRIC},
            ],
        }],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=body,
        headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.load(resp)
        text = "".join(b.get("text", "") for b in payload.get("content", []))
        start, end = text.find("{"), text.rfind("}")
        return json.loads(text[start:end + 1]) if start >= 0 else None
    except Exception as exc:
        print(f"  vlm: {exc}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Contact sheet

def write_contact_sheet(results: list[dict]) -> Path:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    for r in results:
        cards = []
        for c in r["candidates"]:
            badges = [f'<span class="lic">{html.escape(c["license"])}</span>',
                      f'★{c["faves"]}']
            if "fill" in c:
                badges.append(f'fill {c["fill"]}' + (" ✓" if c.get("frame_ok") else ""))
            if "clip" in c:
                badges.append(f'clip {c["clip"]}')
            if "vlm" in c:
                badges.append(f'vlm {c["vlm"]}')
            pick = " pick" if c.get("pick") else ""
            cards.append(
                f'<a class="card{pick}" href="{html.escape(c["obs_url"])}" '
                f'target="_blank"><img loading="lazy" src="{html.escape(c["url"])}">'
                f'<div class="meta">{" · ".join(badges)}</div></a>')
        rows.append(f'<h2>{html.escape(r["name"])} '
                    f'<small>{r["n"]} candidates</small></h2>'
                    f'<div class="grid">{"".join(cards)}</div>')
    doc = (
        "<!doctype html><meta charset=utf-8><title>Kestrel open images</title>"
        "<style>body{font:14px system-ui;margin:24px;background:#111;color:#eee}"
        "h2{margin:28px 0 8px}small{color:#888;font-weight:400}"
        ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:10px}"
        ".card{display:block;border:2px solid #333;border-radius:8px;overflow:hidden;"
        "text-decoration:none;color:#ccc;background:#1a1a1a}"
        ".card img{width:100%;height:150px;object-fit:cover;display:block}"
        ".card.pick{border-color:#4caf50}"
        ".meta{padding:5px 7px;font-size:11px}"
        ".lic{background:#264;padding:1px 5px;border-radius:4px;margin-right:4px}"
        "</style>" + "".join(rows))
    path = OUT_DIR / "contact_sheet.html"
    path.write_text(doc, encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# Main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=len(SAMPLE_SPECIES))
    args = ap.parse_args()

    yolo = _load_yolo()
    clip = load_clip()
    have_vlm = bool(os.environ.get("ANTHROPIC_API_KEY"))
    print(f"stages: framing={'on' if yolo else 'off'} "
          f"clip={'on' if clip else 'off'} vlm={'on' if have_vlm else 'off'}")

    results = []
    for name in SAMPLE_SPECIES[:args.limit]:
        print(f"• {name}")
        tid = resolve_taxon(name)
        if not tid:
            print("  no iNat taxon; skipping")
            continue
        cands = gather_candidates(tid, CANDIDATES_PER_SPECIES)
        print(f"  {len(cands)} candidates")

        # Stage 1 — framing on every candidate (if enabled), then judges on the
        # best-framed few (if enabled).
        if yolo:
            for c in cands:
                fs = framing_score(yolo, c["url"])
                if fs:
                    c.update(fill=fs["fill"], n_birds=fs["n_birds"],
                             centered=fs["centered"], frame_ok=fs["ok"])
            cands.sort(key=lambda c: (c.get("frame_ok", False), c.get("fill", 0)),
                       reverse=True)

        judged = cands[:TOP_K_FOR_JUDGE] if (clip or have_vlm) else []
        for c in judged:
            if clip:
                v = clip_score(clip, c["url"])
                if v is not None:
                    c["clip"] = v
            if have_vlm:
                v = vlm_score(c["url"])
                if v is not None:
                    c["vlm"] = v.get("score")
                    c["vlm_detail"] = v

        # Pick: prefer VLM score, then CLIP, then framing fill, then faves.
        def rank(c: dict):
            return (c.get("vlm", -1), c.get("clip", -1),
                    c.get("fill", 0), c.get("faves", 0))
        if cands:
            best = max(cands, key=rank)
            best["pick"] = True

        results.append({"name": name, "n": len(cands), "taxon_id": tid,
                        "candidates": cands})

    (OUT_DIR).mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "results.json").write_text(json.dumps(results, indent=2), "utf-8")
    sheet = write_contact_sheet(results)
    print(f"\nwrote {sheet}")
    print(f"wrote {OUT_DIR / 'results.json'}")


if __name__ == "__main__":
    main()
