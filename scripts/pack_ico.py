#!/usr/bin/env python3
import os
import struct
import sys


def main() -> None:
    if len(sys.argv) < 3:
        sys.stderr.write("用法：pack_ico.py 输出.ico 边长:图片.png ...\n")
        sys.exit(1)
    dest = sys.argv[1]
    pngs = []
    for spec in sys.argv[2:]:
        size_s, path = spec.split(":", 1)
        with open(path, "rb") as f:
            pngs.append((int(size_s), f.read()))
    offset = 6 + 16 * len(pngs)
    out = bytearray(struct.pack("<HHH", 0, 1, len(pngs)))
    blobs = []
    for size, data in pngs:
        w = 0 if size >= 256 else size
        out += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
        blobs.append(data)
    for blob in blobs:
        out += blob
    folder = os.path.dirname(dest)
    if folder:
        os.makedirs(folder, exist_ok=True)
    with open(dest, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main()
