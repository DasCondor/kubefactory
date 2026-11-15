"""Converts README screenshots to WebP (quality 90, about a sixth of the PNG)
and points the Markdown files at the new names.

    python tools/docs_webp.py docs/overview.png [more.png ...]

The PNG is removed after a successful conversion.
"""
import glob, io, os, sys
from PIL import Image

done = []
for src in sys.argv[1:]:
    dst = os.path.splitext(src)[0] + ".webp"
    Image.open(src).convert("RGB").save(dst, quality=90, method=6)
    os.remove(src)
    done.append((os.path.basename(src), os.path.basename(dst)))
    print("%s -> %s" % (src, dst))

for md in ["README.md", "CONTRIBUTING.md"] + glob.glob("docs/*.md"):
    if not os.path.exists(md):
        continue
    s = io.open(md, encoding="utf-8").read()
    t = s
    for a, b in done:
        t = t.replace(a, b)
    if t != s:
        io.open(md, "w", encoding="utf-8", newline="").write(t)
        print("updated", md)
