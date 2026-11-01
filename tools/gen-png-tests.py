#!/usr/bin/env python3
"""Writes the PNG test vectors for src/tui/png.zig and src/tui/graphics.zig.

src/tui/testdata/png/: tiny vectors, one per colour type and bit depth. The encoder applies every
filter type (rows cycle through 0..4), so the decoder's unfiltering is checked against an
independent implementation.

src/tui/testdata/artwork/: synthetic images laid out like the PNGs Apple's artwork CDN sends
(sRGB, eXIf and XMP iTXt chunks before the image data, a filter picked per row, zlib at level 1,
16 KiB IDAT chunks), at the sizes the app requests. The pixels are gradients, shapes and noise.

Each <name>.png comes with <name>.rgb: the RGB8 pixels the decoder must return (alpha composited
over black, 16-bit samples cut to their high byte), computed from the source pixels rather than
from the encoded file. The 300x300 artwork has no .rgb (it would be 270 KB); its test checks a CRC
of the pixels, which this script prints. Deterministic: rerunning gives the same bytes.

Usage: python3 -I tools/gen-png-tests.py
"""
import os
import random
import struct
import sys
import zlib

TESTDATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "tui", "testdata")
OUT = os.path.join(TESTDATA, "png")
ART_OUT = os.path.join(TESTDATA, "artwork")


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def chunks(png):
    """(type, data) of each chunk in `png`."""
    pos = 8
    while pos < len(png):
        n, = struct.unpack(">I", png[pos:pos + 4])
        yield png[pos + 4:pos + 8], png[pos + 8:pos + 8 + n]
        pos += 12 + n


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def filter_row(kind, row, prev, bpp):
    out = bytearray()
    for i, x in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        pred = [0, a, b, (a + b) >> 1, paeth(a, b, c)][kind]
        out.append((x - pred) & 255)
    return bytes([kind]) + bytes(out)


def adaptive_filter_row(row, prev, bpp):
    """libpng's heuristic: the filter whose output bytes, read as signed, sum smallest."""
    def cost(filtered):
        return sum(min(v, 256 - v) for v in filtered[1:])
    return min((filter_row(kind, row, prev, bpp) for kind in range(5)), key=cost)


def pack_row(samples, depth):
    """Packs one row of samples (ints) at `depth` bits, MSB first, padding the last byte."""
    if depth == 8:
        return bytes(samples)
    if depth == 16:
        return b"".join(struct.pack(">H", s) for s in samples)
    out = bytearray()
    acc, bits = 0, 0
    for s in samples:
        acc = (acc << depth) | s
        bits += depth
        if bits == 8:
            out.append(acc)
            acc, bits = 0, 0
    if bits:
        out.append(acc << (8 - bits))
    return bytes(out)


CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def build(width, height, color_type, depth, pixels, plte=None, trns=None, idat_parts=1, extra=(),
          adaptive=False, level=9, wbits=15, idat_size=None):
    """pixels: rows of tuples of samples. Returns the PNG bytes and the filter type of each row.

    Rows cycle through filters 0..4 unless `adaptive`. `level` and `wbits` go to zlib. The image
    stream is cut into `idat_parts` equal IDATs, or into IDATs of `idat_size` bytes."""
    ch = CHANNELS[color_type]
    bpp = max(1, ch * depth // 8)
    raw = bytearray()
    filters = []
    prev = bytes(len(pack_row([0] * (width * ch), depth)))
    for y, row in enumerate(pixels):
        packed = pack_row([s for px in row for s in px], depth)
        filtered = adaptive_filter_row(packed, prev, bpp) if adaptive else filter_row(y % 5, packed, prev, bpp)
        raw += filtered
        filters.append(filtered[0])
        prev = packed
    z = zlib.compressobj(level, zlib.DEFLATED, wbits)
    z = z.compress(bytes(raw)) + z.flush()
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 0))
    for kind, data in extra:
        png += chunk(kind, data)
    if plte is not None:
        png += chunk(b"PLTE", b"".join(bytes(c) for c in plte))
    if trns is not None:
        png += chunk(b"tRNS", trns)
    step = idat_size or -(-len(z) // idat_parts)
    for i in range(0, len(z), step):
        png += chunk(b"IDAT", z[i:i + step])
    return png + chunk(b"IEND", b""), filters


def over_black(c, a):
    return (c * a + 127) // 255


def expected(color_type, depth, pixels, plte=None, trns=None):
    out = bytearray()
    maxval = (1 << depth) - 1
    key = None
    if trns is not None and color_type == 0:
        key = struct.unpack(">H", trns)
    if trns is not None and color_type == 2:
        key = struct.unpack(">HHH", trns)

    def to8(s):
        if depth == 16:
            return s >> 8
        return s * 255 // maxval

    for row in pixels:
        for px in row:
            if color_type == 3:
                r, g, b = plte[px[0]]
                a = trns[px[0]] if trns is not None and px[0] < len(trns) else 255
                out += bytes([over_black(r, a), over_black(g, a), over_black(b, a)])
            elif color_type in (0, 4):
                v = to8(px[0])
                a = to8(px[1]) if color_type == 4 else 255
                if key is not None and px == key:
                    a = 0
                out += bytes([over_black(v, a)] * 3)
            else:
                rgb = [to8(s) for s in px[:3]]
                a = to8(px[3]) if color_type == 6 else 255
                if key is not None and px == key:
                    a = 0
                out += bytes(over_black(c, a) for c in rgb)
    return bytes(out)


def exif(width, height, comment):
    """A big-endian eXIf with the four tags the CDN writes: UserComment, ColorSpace (sRGB) and the
    pixel dimensions, in an Exif IFD that IFD0 points to."""
    comment = b"ASCII\0\0\0" + comment.encode()
    ifd0 = struct.pack(">H", 1) + struct.pack(">HHII", 0x8769, 4, 1, 26) + struct.pack(">I", 0)
    data_at = 26 + 2 + 4 * 12 + 4
    exif_ifd = struct.pack(">H", 4) + b"".join([
        struct.pack(">HHII", 0x9286, 7, len(comment), data_at),
        struct.pack(">HHIHH", 0xA001, 3, 1, 1, 0),
        struct.pack(">HHII", 0xA002, 4, 1, width),
        struct.pack(">HHII", 0xA003, 4, 1, height),
    ]) + struct.pack(">I", 0)
    return b"MM\0*" + struct.pack(">I", 8) + ifd0 + exif_ifd + comment


def xmp(comment):
    """An uncompressed iTXt holding XMP, as the CDN writes it."""
    text = (
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">\n'
        '   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '      <rdf:Description rdf:about=""\n'
        '            xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
        '            xmlns:exif="http://ns.adobe.com/exif/1.0/">\n'
        '         <dc:creator>\n'
        '            <rdf:Seq>\n'
        f'               <rdf:li>{comment}</rdf:li>\n'
        '            </rdf:Seq>\n'
        '         </dc:creator>\n'
        f'         <exif:UserComment>{comment}</exif:UserComment>\n'
        '      </rdf:Description>\n'
        '   </rdf:RDF>\n'
        '</x:xmpmeta>\n'
    )
    return b"XML:com.adobe.xmp\0\0\0\0\0" + text.encode()


def cdn_chunks(name, width, height):
    comment = name.upper().replace("-", "").ljust(26, "X")  # the CDN's comments are 26 characters
    return [(b"sRGB", b"\0"), (b"eXIf", exif(width, height, comment)), (b"iTXt", xmp(comment))]


def clamp(v):
    return max(0, min(255, int(round(v))))


def album_64(rng):
    """RGB: a diagonal gradient, a disc and a dark bar, with grain."""
    n, rows = 64, []
    for y in range(n):
        row = []
        for x in range(n):
            c = (40 + 150 * x / 63, 30 + 120 * y / 63, 160 - 100 * (x + y) / 126)
            if (x - 40) ** 2 + (y - 24) ** 2 <= 14 ** 2:
                c = (230, 190, 60)
            if 6 <= x < 27 and 44 <= y < 57:
                c = (20, 20, 30)
            row.append(tuple(clamp(v + rng.uniform(-12, 12)) for v in c))
        rows.append(row)
    return rows


def artist_64(rng):
    """RGBA: a head-and-shoulders silhouette on a dark backdrop under a band of black-and-white
    speckle (the rows that pick filter 0); the bottom rows fade to translucent."""
    n, rows = 64, []
    for y in range(n):
        row = []
        for x in range(n):
            if y < 4:
                v = rng.choice((rng.randint(0, 5), rng.randint(250, 255)))
                c = (v, v, v)
            else:
                c = (25 + y / 2, 20 + y / 3, 40 + y / 2)
                head = (x - 32) ** 2 + (y - 26) ** 2 <= 12 ** 2
                body = ((x - 32) / 26) ** 2 + ((y - 64) / 20) ** 2 <= 1
                if head or body:
                    c = (200 - y, 150 - y / 2, 120)
                c = tuple(clamp(v + rng.uniform(-8, 8)) for v in c)
            a = 255 if y < 48 else 255 - (y - 47) * 8
            row.append(c + (a,))
        rows.append(row)
    return rows


def station_300(rng):
    """RGB: a smooth two-axis gradient with a soft glow, under texture enough that the image
    stream runs to five 16 KiB IDATs. The texture changes by band (vertical streaks, fine grain,
    streaks along both axes) so the rows pick different filters."""
    n, rows = 300, []
    cols = [rng.uniform(-12, 12) for _ in range(n)]
    lines = [rng.uniform(-4, 4) for _ in range(n)]
    for y in range(n):
        row = []
        for x in range(n):
            t, u = x / 299, y / 299
            glow = max(0.0, 1 - ((x - 190) ** 2 + (y - 120) ** 2) / 90 ** 2)
            c = (230 - 140 * t + 25 * glow, 50 + 60 * u + 120 * glow, 90 + 120 * t * u + 60 * glow)
            if y < 150:
                texture = cols[x]
            elif y < 200:
                texture = rng.uniform(-2, 2)
            else:
                texture = cols[x] + lines[y]
            row.append(tuple(clamp(v + texture) for v in c))
        rows.append(row)
    return rows


def artwork():
    """The CDN-shaped artwork; returns the CRC of the 300x300 image's pixels."""
    os.makedirs(ART_OUT, exist_ok=True)
    rng = random.Random(20261101)
    # name, colour type, pixels, zlib window bits, the set of filter types the rows must use
    images = [
        ("album-64-rgb", 2, album_64(rng), 14, {1, 2, 3, 4}),  # a 16 KiB window, as for small images
        ("artist-64-rgba", 6, artist_64(rng), 15, {0, 1, 2, 3, 4}),
        ("station-300-rgb", 2, station_300(rng), 15, {1, 2, 3, 4}),
    ]
    crc = None
    for name, ct, pixels, wbits, want_filters in images:
        size = len(pixels)
        png, filters = build(size, size, ct, 8, pixels, extra=cdn_chunks(name, size, size), adaptive=True,
                             level=1, wbits=wbits, idat_size=16384)
        assert set(filters) == want_filters, (name, sorted(set(filters)))
        rgb = expected(ct, 8, pixels)
        with open(os.path.join(ART_OUT, name + ".png"), "wb") as f:
            f.write(png)
        if size == 300:
            idats = sum(1 for kind, _ in chunks(png) if kind == b"IDAT")
            assert idats == 5, (name, idats)
            crc = zlib.crc32(rgb)
        else:
            with open(os.path.join(ART_OUT, name + ".rgb"), "wb") as f:
                f.write(rgb)
        print(name, len(png), "bytes, filters", sorted(set(filters)), file=sys.stderr)
    return crc


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(20261019)
    vectors = []
    w, h = 7, 10  # odd width: partial bytes at low depths; 10 rows: every filter twice

    def rows(ch, maxval):
        return [[tuple(rng.randint(0, maxval) for _ in range(ch)) for _ in range(w)] for _ in range(h)]

    for depth in (1, 2, 4, 8, 16):
        vectors.append((f"gray{depth}", w, h, 0, depth, rows(1, (1 << depth) - 1), {}))
    for depth in (8, 16):
        vectors.append((f"rgb{depth}", w, h, 2, depth, rows(3, (1 << depth) - 1), {}))
        vectors.append((f"grayalpha{depth}", w, h, 4, depth, rows(2, (1 << depth) - 1), {}))
        vectors.append((f"rgba{depth}", w, h, 6, depth, rows(4, (1 << depth) - 1), {}))
    for depth in (1, 2, 4, 8):
        n = 1 << depth
        plte = [tuple(rng.randint(0, 255) for _ in range(3)) for _ in range(n)]
        trns = bytes(rng.randint(0, 255) for _ in range(max(1, n // 2)))  # shorter than PLTE: the rest are opaque
        vectors.append((f"palette{depth}", w, h, 3, depth, rows(1, n - 1), {"plte": plte, "trns": trns}))
    # A colour key: some pixels equal it and turn black.
    px = rows(3, 255)
    px[0][0] = px[3][4] = (10, 20, 30)
    vectors.append(("rgb8-key", w, h, 2, 8, px, {"trns": struct.pack(">HHH", 10, 20, 30)}))
    # Several IDATs and ancillary chunks before them, as Apple's artwork CDN sends.
    vectors.append(("rgb8-split", w, h, 2, 8, rows(3, 255), {
        "idat_parts": 3,
        "extra": [(b"sRGB", b"\x00"), (b"tEXt", b"Comment\x00test vector")],
    }))
    vectors.append(("rgb8-1x1", 1, 1, 2, 8, [[(200, 100, 50)]], {}))

    for name, width, height, ct, depth, pixels, opts in vectors:
        png, _ = build(width, height, ct, depth, pixels, plte=opts.get("plte"), trns=opts.get("trns"),
                       idat_parts=opts.get("idat_parts", 1), extra=opts.get("extra", ()))
        rgb = expected(ct, depth, pixels, plte=opts.get("plte"), trns=opts.get("trns"))
        assert len(rgb) == width * height * 3
        with open(os.path.join(OUT, name + ".png"), "wb") as f:
            f.write(png)
        with open(os.path.join(OUT, name + ".rgb"), "wb") as f:
            f.write(rgb)
        print(name, len(png), "bytes", file=sys.stderr)

    crc = artwork()
    print(f"station-300-rgb pixels: CRC-32 0x{crc:08x} (the expectation in src/tui/png.zig)", file=sys.stderr)


if __name__ == "__main__":
    main()
