"""Turns fly-through frames into the README animation (animated WebP).

    play.bat --demo --flythrough=<frames dir>
    python tools/make_gif.py <frames dir> docs/flythrough.webp [ms per frame]

A .gif output name still writes a GIF (128 colours), about six times larger.
"""
import glob, sys
from PIL import Image

ms = int(sys.argv[3]) if len(sys.argv) > 3 else 90

frames = [Image.open(f).convert("RGB") for f in sorted(glob.glob(sys.argv[1] + "/f*.png"))]
if sys.argv[2].lower().endswith(".gif"):
    pal = frames[len(frames) // 2].quantize(colors=128, method=Image.Quantize.MEDIANCUT)
    frames = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
    frames[0].save(sys.argv[2], save_all=True, append_images=frames[1:], duration=ms, loop=0, optimize=True)
else:
    frames[0].save(sys.argv[2], save_all=True, append_images=frames[1:], duration=ms, loop=0, quality=80, method=6)
print(len(frames), "frames ->", sys.argv[2])
