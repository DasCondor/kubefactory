"""Turns fly-through frames into the README gif.

    play.bat --demo --flythrough=<frames dir>
    python tools/make_gif.py <frames dir> docs/flythrough.gif
"""
import glob, sys
from PIL import Image

frames = [Image.open(f).convert("RGB") for f in sorted(glob.glob(sys.argv[1] + "/f*.png"))]
pal = frames[len(frames) // 2].quantize(colors=128, method=Image.Quantize.MEDIANCUT)
out = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
out[0].save(sys.argv[2], save_all=True, append_images=out[1:], duration=90, loop=0, optimize=True)
print(len(out), "frames ->", sys.argv[2])
