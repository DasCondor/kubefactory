"""Seat the Krew's hand-held props in their hands.

The V6/V7 Krew models (Gauge, Blueprint, the Foreman variants) carry a tablet or a
laptop that floats 11-22 cm in front of the right hand, held up only by a small
bracket, so it reads as stuck on rather than held. This moves those parts (and the
small hand mount, which would otherwise poke through them), in
every detail level, so the fingers close on the tablet's lower edge and the laptop
rests on the fingers. Nothing else in a model moves.

    python tools/fix_held_items.py            # report and fix
    python tools/fix_held_items.py --check    # report only; exit 1 if anything floats

It edits assets/krew/*.glb in place (vertex positions and accessor bounds only, so
the files keep their layout) and keeps the HandDisplay anchor and the bounds in
assets/catalog.json in step. Running it again changes nothing.
"""
import glob
import hashlib
import json
import os
import struct
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KREW = os.path.join(ROOT, "assets", "krew")
CATALOG = os.path.join(ROOT, "assets", "catalog.json")

# group -> (the part the placement is measured from, every part that moves with it)
GROUPS = {
    "tablet": (("HandDisplayFrame_", "PlanningSlateFrame_"),
               ("HandDisplayFrame_", "HandDisplay_", "PlanningSlateFrame_", "PlanningSlate_", "HeldDisplayBracket_", "HandToolMount_")),
    "laptop": (("LaptopKeyboard_",), ("Laptop", "HandToolMount_")),
}
FINGERS = ("RightFingerProx_", "RightFingerDist_")
TOLERANCE = 0.005          # metres; closer than this counts as already seated


def read_glb(path):
    b = open(path, "rb").read()
    jlen = struct.unpack_from("<I", b, 12)[0]
    gltf = json.loads(b[20:20 + jlen])
    boff = 20 + jlen
    blen = struct.unpack_from("<I", b, boff)[0]
    return gltf, bytearray(b[boff + 8: boff + 8 + blen])


def write_glb(path, gltf, binb):
    j = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    j += b" " * ((4 - len(j) % 4) % 4)
    binb = bytes(binb) + b"\0" * ((4 - len(binb) % 4) % 4)
    total = 12 + 8 + len(j) + 8 + len(binb)
    out = struct.pack("<III", 0x46546C67, 2, total)
    out += struct.pack("<II", len(j), 0x4E4F534A) + j
    out += struct.pack("<II", len(binb), 0x004E4942) + binb
    open(path, "wb").write(out)


def positions(gltf, binb, mesh):
    """A writable (n, 3) float32 view of a mesh's vertex positions, and its accessor."""
    acc = gltf["accessors"][gltf["meshes"][mesh]["primitives"][0]["attributes"]["POSITION"]]
    bv = gltf["bufferViews"][acc["bufferView"]]
    off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride", 12) // 4
    arr = np.frombuffer(binb, dtype=np.float32, count=acc["count"] * stride, offset=off).reshape(-1, stride)
    return arr[:, :3], acc


def parts(gltf, binb):
    out = []
    for node in gltf["nodes"]:
        if node.get("mesh") is not None:
            p, acc = positions(gltf, binb, node["mesh"])
            out.append((node.get("name", ""), p, acc))
    return out


def delta_for(group, ref, fingers):
    fc = (fingers.min(0) + fingers.max(0)) / 2
    lo = ref.min(0)
    if group == "tablet":
        # the lower edge sits in the fist: 2 cm below the fingers' middle, its back
        # 3 cm behind their middle, so fingers and thumb pinch it
        return np.array([0.0, fc[1] - 0.02 - lo[1], fc[2] - 0.03 - lo[2]], dtype=np.float32)
    # the laptop rests flat on the fingers
    return np.array([0.0, fingers.max(0)[1] - lo[1], 0.0], dtype=np.float32)


def model_id(path):
    base = os.path.basename(path)[:-4]
    return base.rsplit("_", 1)


def main():
    check = "--check" in sys.argv
    catalog = json.load(open(CATALOG, encoding="utf-8"))
    entries = {m["id"]: m for m in catalog["models"]}
    changed_catalog = False
    floating = []
    for path in sorted(glob.glob(os.path.join(KREW, "*.glb"))):
        gltf, binb = read_glb(path)
        ps = parts(gltf, binb)
        fing = [p for n, p, a in ps if n.startswith(FINGERS)]
        if not fing:
            continue
        fingers = np.vstack(fing)
        moved = False
        for group, (ref_names, members) in GROUPS.items():
            ref = [p for n, p, a in ps if n.startswith(ref_names)]
            if not ref:
                continue
            d = delta_for(group, ref[0], fingers)
            if np.abs(d).max() < TOLERANCE:
                continue
            mid, tier = model_id(path)
            floating.append("%s %s: %s %.0f cm from the hand" % (mid, tier, group, np.linalg.norm(d) * 100))
            if check:
                continue
            for n, p, acc in ps:
                if n.startswith(members):
                    p += d
                    acc["min"] = [float(x) for x in p.min(0)]
                    acc["max"] = [float(x) for x in p.max(0)]
            variant = entries.get(mid, {}).get("variants", {}).get(tier)
            if variant is not None:
                hd = variant.get("anchors", {}).get("HandDisplay")
                if group == "tablet" and isinstance(hd, dict) and isinstance(hd.get("position"), list):
                    hd["position"] = [round(float(v) + float(dv), 6) for v, dv in zip(hd["position"], d)]
                    changed_catalog = True
            moved = True
        if moved:
            write_glb(path, gltf, binb)
            allp = np.vstack([p for n, p, a in parts(gltf, binb)])
            mid, tier = model_id(path)
            variant = entries.get(mid, {}).get("variants", {}).get(tier)
            if variant is not None:          # a changed file is re-hashed and marked for review
                variant["sha256"] = hashlib.sha256(open(path, "rb").read()).hexdigest()
                changed_catalog = True
                note = "held prop seated in hand by tools/fix_held_items.py; in-game review pending"
                entry = entries[mid]
                if note not in entry.get("release_quality_status", ""):
                    entry["release_quality_status"] = (entry.get("release_quality_status", "") + "; " + note).lstrip("; ")
            if variant is not None and "bounds" in variant:
                lo, hi = allp.min(0), allp.max(0)
                old = variant["bounds"]          # keep a value unless it really moved (float32 noise)
                variant["bounds"] = [[o if abs(o - float(n)) < 1e-4 else round(float(n), 6) for o, n in zip(old[i], new)]
                                     for i, new in enumerate([lo, hi])]
                changed_catalog = True
    for line in floating:
        print(("FLOATS  " if check else "seated  ") + line)
    if changed_catalog:
        with open(CATALOG, "w", encoding="utf-8", newline="\n") as f:
            json.dump(catalog, f, indent=2, ensure_ascii=False)     # the file's own layout: no final newline
    if not floating:
        print("every held prop is in its hand")
    sys.exit(1 if (check and floating) else 0)


if __name__ == "__main__":
    main()
