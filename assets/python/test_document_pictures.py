"""A document's pictures, the way the host asks for them.

Run with ``python3 assets/python/test_document_pictures.py``.

The host keeps the room for a picture only if the content says how big it is,
so :func:`picture_size` is checked on every format the host decodes; and the
bytes are asked for later, by ``document.picture``, so that is called the way
the host calls it — by handle and key, after the answer has gone.
"""

import base64
import struct
import sys
import zlib

from xverb import Picture, Plugin, picture_size
from xverb.rpc import RpcError


def png(width, height):
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    chunk = b"IHDR" + header
    return (b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(header)) + chunk
            + struct.pack(">I", zlib.crc32(chunk)))


def jpeg(width, height):
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, height, width, 1) + b"\x01\x11\x00"
    return b"\xff\xd8" + app0 + sof + b"\xff\xd9"


def gif(width, height):
    return b"GIF89a" + struct.pack("<HH", width, height) + b"\x00\x00\x00"


def bmp(width, height):
    return b"BM" + b"\x00" * 16 + struct.pack("<ii", width, -height) + b"\x00" * 8


def webp_lossless(width, height):
    bits = (width - 1) | ((height - 1) << 14)
    body = b"VP8L" + struct.pack("<I", 5) + b"\x2f" + bits.to_bytes(4, "little")
    return b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WEBP" + body


failed = []


def check(name, got, want):
    if got != want:
        failed.append(name)
        print("FAIL %s: %r, wanted %r" % (name, got, want))
    else:
        print("ok   %s" % name)


check("png", picture_size(png(640, 480)), (640, 480))
check("jpeg", picture_size(jpeg(1200, 800)), (1200, 800))
check("gif", picture_size(gif(32, 16)), (32, 16))
check("bmp stored top-down", picture_size(bmp(100, 50)), (100, 50))
check("webp lossless", picture_size(webp_lossless(300, 200)), (300, 200))
check("not a picture", picture_size(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), None)
check("cut short", picture_size(b"\x89PNG\r\n\x1a\n"), None)

plugin = Plugin("org.xverb.test")
asked = []


def later():
    asked.append("cover")
    return png(10, 20)


content = plugin.document(
    "# Book\n\n![Cover](picture:cover)\n\n![Map](picture:map)\n",
    {"cover": Picture(later, 10, 20), "map": Picture(jpeg(1200, 800)), "odd": Picture(b"??")},
)
pictures = content.get("pictures") or {}
check("kind", content.get("kind"), "markdown")
check("every key named", sorted(pictures.get("ids", [])), ["cover", "map", "odd"])
check("sizes given and read", pictures.get("sizes"), {"cover": [10, 20], "map": [1200, 800]})
check("nothing read while opening", asked, [])

answer = plugin._document_picture({"handle": pictures["handle"], "id": "cover"})
check("bytes when asked", base64.b64decode(answer["data"]), png(10, 20))
check("read once asked", asked, ["cover"])

try:
    plugin._document_picture({"handle": pictures["handle"], "id": "nobody"})
    check("unknown key refused", "answered", "refused")
except RpcError:
    check("unknown key refused", "refused", "refused")

check("no pictures, plain markdown", plugin.document("text"), {"kind": "markdown", "text": "text", "truncated": False})

for _ in range(Plugin.KEEP_DOCUMENTS):
    plugin.document("x", {"a": Picture(png(1, 1))})
try:
    plugin._document_picture({"handle": pictures["handle"], "id": "cover"})
    check("an old document is let go", "answered", "refused")
except RpcError:
    check("an old document is let go", "refused", "refused")

sys.exit(1 if failed else 0)
