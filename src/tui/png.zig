//! A small PNG decoder for album artwork in the half-block fallback. Kitty terminals take the PNG
//! as is; only terminals without an image protocol need the pixels.
//!
//! Supports every non-interlaced PNG: colour types 0, 2, 3, 4 and 6 at all their bit depths,
//! filters 0–4, `tRNS`. Every chunk's CRC is checked. The result is RGB8 with alpha composited
//! over black; 16-bit samples keep their high byte.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 3` bytes, rows top to bottom.
    rgb: []u8,

    pub fn deinit(img: Image, gpa: Allocator) void {
        gpa.free(img.rgb);
    }

    pub fn pixel(img: Image, x: u32, y: u32) [3]u8 {
        const i = (@as(usize, y) * img.width + x) * 3;
        return img.rgb[i..][0..3].*;
    }
};

pub const Error = error{
    /// No PNG signature (a JPEG, or an error page).
    NotPng,
    /// The data ends inside a chunk or before IEND.
    Truncated,
    BadCrc,
    /// A malformed header, chunk or image stream.
    BadPng,
    /// Valid, but not handled here: interlaced, or an unknown critical chunk.
    Unsupported,
    /// More than `max_pixels`.
    TooLarge,
} || Allocator.Error;

/// Artwork is requested at a few hundred pixels; this only bounds what a header can make the
/// decoder allocate (at most 32 MiB of 16-bit RGBA rows plus 12 MiB of RGB).
pub const max_pixels = 2048 * 2048;

pub const signature = "\x89PNG\r\n\x1a\n";

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color_type: u8,

    fn channels(h: Header) u8 {
        return switch (h.color_type) {
            0, 3 => 1,
            4 => 2,
            2 => 3,
            6 => 4,
            else => unreachable,
        };
    }

    fn bitsPerPixel(h: Header) usize {
        return @as(usize, h.channels()) * h.depth;
    }

    /// Bytes per row, without the filter byte.
    fn stride(h: Header) usize {
        return (h.width * h.bitsPerPixel() + 7) / 8;
    }

    /// The distance back to the matching byte of the pixel on the left, as the filters use it.
    fn filterBpp(h: Header) usize {
        return @max(1, h.bitsPerPixel() / 8);
    }
};

/// Decodes `bytes` into a caller-owned image (`Image.deinit`).
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Image {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;

    var header: ?Header = null;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    var pos: usize = signature.len;
    var ended = false;
    while (!ended) {
        if (bytes.len - pos < 12) return error.Truncated;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (len > std.math.maxInt(i32)) return error.BadPng;
        if (bytes.len - pos - 12 < len) return error.Truncated;
        const type_and_data = bytes[pos + 4 ..][0 .. 4 + len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(type_and_data) != crc) return error.BadCrc;
        pos += 12 + len;

        const kind = type_and_data[0..4];
        const data = type_and_data[4..];
        if (header == null and !std.mem.eql(u8, kind, "IHDR")) return error.BadPng;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (header != null) return error.BadPng;
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (data.len == 0 or data.len % 3 != 0 or data.len > 256 * 3) return error.BadPng;
            palette = data;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            ended = true;
        } else if (kind[0] & 0x20 == 0) {
            // An unknown critical chunk (upper-case first letter) changes how to read the image.
            return error.Unsupported;
        }
    }

    const h = header.?;
    if (h.color_type == 3 and palette.len == 0) return error.BadPng;
    const stride = h.stride();
    // One spare byte: see `inflate`.
    const raw_buf = try gpa.alloc(u8, h.height * (1 + stride) + 1);
    defer gpa.free(raw_buf);
    const raw = raw_buf[0 .. raw_buf.len - 1];
    try inflate(idat.items, raw_buf);
    try unfilter(h, raw);

    const rgb = try gpa.alloc(u8, @as(usize, h.width) * h.height * 3);
    errdefer gpa.free(rgb);
    for (0..h.height) |y| {
        const row = raw[y * (1 + stride) + 1 ..][0..stride];
        toRgb(h, row, palette, trns, rgb[y * h.width * 3 ..][0 .. h.width * 3]);
    }
    return .{ .width = h.width, .height = h.height, .rgb = rgb };
}

fn parseHeader(data: []const u8) Error!Header {
    if (data.len != 13) return error.BadPng;
    const h: Header = .{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .depth = data[8],
        .color_type = data[9],
    };
    if (h.width == 0 or h.height == 0) return error.BadPng;
    if (data[10] != 0 or data[11] != 0) return error.BadPng; // compression, filter method
    const depth_ok = switch (h.color_type) {
        0 => switch (h.depth) {
            1, 2, 4, 8, 16 => true,
            else => false,
        },
        3 => switch (h.depth) {
            1, 2, 4, 8 => true,
            else => false,
        },
        2, 4, 6 => h.depth == 8 or h.depth == 16,
        else => return error.BadPng,
    };
    if (!depth_ok) return error.BadPng;
    switch (data[12]) {
        0 => {},
        1 => return error.Unsupported, // Adam7
        else => return error.BadPng,
    }
    if (@as(u64, h.width) * h.height > max_pixels) return error.TooLarge;
    return h;
}

/// Inflates the zlib stream into all but the last byte of `out`, which it must fill exactly.
/// The spare byte matters: the decompressor asks for room before every stored block, even an
/// empty one (a sync flush), so a buffer that is already full would fail on a valid stream.
fn inflate(zlib: []const u8, out: []u8) Error!void {
    var in: Io.Reader = .fixed(zlib);
    // Direct mode: `out` itself holds the history the back-references need.
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var w: Io.Writer = .fixed(out);
    const n = d.reader.streamRemaining(&w) catch |e| switch (e) {
        // More data than the header allows.
        error.WriteFailed => return error.BadPng,
        error.ReadFailed => {
            const cut = if (d.err) |cause| cause == error.EndOfStream else false;
            return if (cut) error.Truncated else error.BadPng;
        },
    };
    if (n > out.len - 1) return error.BadPng;
    if (n < out.len - 1) return error.Truncated;
}

/// Undoes the per-row filters in place. `raw` is rows of one filter byte plus `stride` bytes.
fn unfilter(h: Header, raw: []u8) Error!void {
    const stride = h.stride();
    const bpp = h.filterBpp();
    var prev: ?[]const u8 = null;
    for (0..h.height) |y| {
        const start = y * (1 + stride);
        const filter = raw[start];
        const row = raw[start + 1 ..][0..stride];
        switch (filter) {
            0 => {},
            1 => for (bpp..stride) |i| {
                row[i] +%= row[i - bpp];
            },
            2 => if (prev) |up| for (row, up) |*x, b| {
                x.* +%= b;
            },
            3 => for (row, 0..) |*x, i| {
                const a: u16 = if (i >= bpp) row[i - bpp] else 0;
                const b: u16 = if (prev) |up| up[i] else 0;
                x.* +%= @intCast((a + b) / 2);
            },
            4 => for (row, 0..) |*x, i| {
                const a = if (i >= bpp) row[i - bpp] else 0;
                const b = if (prev) |up| up[i] else 0;
                const c = if (i >= bpp) if (prev) |up| up[i - bpp] else 0 else 0;
                x.* +%= paeth(a, b, c);
            },
            else => return error.BadPng,
        }
        prev = row;
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Converts one unfiltered row to RGB8 over black.
fn toRgb(h: Header, row: []const u8, palette: []const u8, trns: []const u8, out: []u8) void {
    const channels = h.channels();
    for (0..h.width) |x| {
        const o = out[x * 3 ..][0..3];
        if (h.color_type == 3) {
            const index = sample(row, h.depth, x);
            if (index * 3 + 3 > palette.len) {
                // An index past the palette: the spec calls it an error; draw black.
                o.* = .{ 0, 0, 0 };
                continue;
            }
            const alpha: u8 = if (index < trns.len) trns[index] else 255;
            for (0..3) |i| o[i] = over(palette[index * 3 + i], alpha);
            continue;
        }
        var s: [4]u16 = undefined;
        for (0..channels) |c| s[c] = sample(row, h.depth, x * channels + c);
        var alpha: u8 = switch (h.color_type) {
            4 => to8(s[1], h.depth),
            6 => to8(s[3], h.depth),
            else => 255,
        };
        // tRNS on grey or RGB names one colour (at full depth) as transparent.
        if (h.color_type == 0 and trns.len == 2 and s[0] == std.mem.readInt(u16, trns[0..2], .big)) alpha = 0;
        if (h.color_type == 2 and trns.len == 6 and
            s[0] == std.mem.readInt(u16, trns[0..2], .big) and
            s[1] == std.mem.readInt(u16, trns[2..4], .big) and
            s[2] == std.mem.readInt(u16, trns[4..6], .big)) alpha = 0;
        switch (h.color_type) {
            0, 4 => o.* = @splat(over(to8(s[0], h.depth), alpha)),
            2, 6 => for (0..3) |i| {
                o[i] = over(to8(s[i], h.depth), alpha);
            },
            else => unreachable,
        }
    }
}

/// The `i`-th sample of a row packed at `depth` bits, most significant bits first.
fn sample(row: []const u8, depth: u8, i: usize) u16 {
    return switch (depth) {
        8 => row[i],
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        1, 2, 4 => {
            const bit = i * depth;
            const shift: u3 = @intCast(8 - depth - bit % 8);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            return (row[bit / 8] >> shift) & mask;
        },
        else => unreachable,
    };
}

/// Scales a sample of `depth` bits to 8 bits.
fn to8(s: u16, depth: u8) u8 {
    return switch (depth) {
        8 => @intCast(s),
        16 => @intCast(s >> 8),
        1 => @intCast(s * 255),
        2 => @intCast(s * 85),
        4 => @intCast(s * 17),
        else => unreachable,
    };
}

/// `c` composited over black with `alpha`, rounded.
fn over(c: u8, alpha: u8) u8 {
    return @intCast((@as(u16, c) * alpha + 127) / 255);
}

const testing = std.testing;

/// Decodes `name.png` from testdata/png and compares it with `name.rgb` (made by
/// tools/gen-png-tests.py, whose encoder applies every filter type).
fn expectVector(comptime name: []const u8, width: u32, height: u32) !void {
    const img = try decode(testing.allocator, @embedFile("testdata/png/" ++ name ++ ".png"));
    defer img.deinit(testing.allocator);
    try testing.expectEqual(width, img.width);
    try testing.expectEqual(height, img.height);
    try testing.expectEqualSlices(u8, @embedFile("testdata/png/" ++ name ++ ".rgb"), img.rgb);
}

test "grey at every bit depth" {
    try expectVector("gray1", 7, 10);
    try expectVector("gray2", 7, 10);
    try expectVector("gray4", 7, 10);
    try expectVector("gray8", 7, 10);
    try expectVector("gray16", 7, 10);
}

test "RGB, grey+alpha and RGBA at 8 and 16 bits; alpha goes over black" {
    try expectVector("rgb8", 7, 10);
    try expectVector("rgb16", 7, 10);
    try expectVector("grayalpha8", 7, 10);
    try expectVector("grayalpha16", 7, 10);
    try expectVector("rgba8", 7, 10);
    try expectVector("rgba16", 7, 10);
}

test "palette at every bit depth, with a tRNS shorter than the palette" {
    try expectVector("palette1", 7, 10);
    try expectVector("palette2", 7, 10);
    try expectVector("palette4", 7, 10);
    try expectVector("palette8", 7, 10);
}

test "tRNS colour key, split IDAT with ancillary chunks, 1x1" {
    try expectVector("rgb8-key", 7, 10);
    try expectVector("rgb8-split", 7, 10);
    try expectVector("rgb8-1x1", 1, 1);
}

// Synthetic artwork laid out like the PNGs Apple's artwork CDN sends: sRGB, eXIf and XMP chunks
// before the image data, a filter picked per row, zlib at level 1, 16 KiB IDATs (made by
// tools/gen-png-tests.py). The references come from the source pixels. macOS `sips` (to BMP)
// decodes all three to the same pixels: byte for byte, the station by its CRC, and the RGBA one
// after blending over black with rounding.
test "CDN-shaped artwork: 64x64 RGB with a 16 KiB zlib window" {
    const img = try decode(testing.allocator, @embedFile("testdata/artwork/album-64-rgb.png"));
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 64), img.width);
    try testing.expectEqualSlices(u8, @embedFile("testdata/artwork/album-64-rgb.rgb"), img.rgb);
}

test "CDN-shaped artwork: 64x64 RGBA using all five filters" {
    const img = try decode(testing.allocator, @embedFile("testdata/artwork/artist-64-rgba.png"));
    defer img.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, @embedFile("testdata/artwork/artist-64-rgba.rgb"), img.rgb);
}

test "CDN-shaped artwork: 300x300 RGB in five IDAT chunks" {
    const img = try decode(testing.allocator, @embedFile("testdata/artwork/station-300-rgb.png"));
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 300), img.width);
    try testing.expectEqual(@as(u32, 300), img.height);
    // zlib.crc32 of the reference pixels (the full dump is 270 KB); the generator prints it.
    try testing.expectEqual(@as(u32, 0x325e5b33), std.hash.Crc32.hash(img.rgb));
    try testing.expectEqual([3]u8{ img.rgb[0], img.rgb[1], img.rgb[2] }, img.pixel(0, 0));
}

/// A copy of `png` with the chunk at `offset` (its length field) given new data bytes and a fixed CRC.
fn patched(png: []const u8, offset: usize, data_index: usize, value: u8) ![]u8 {
    const copy = try testing.allocator.dupe(u8, png);
    const len = std.mem.readInt(u32, copy[offset..][0..4], .big);
    copy[offset + 8 + data_index] = value;
    std.mem.writeInt(u32, copy[offset + 8 + len ..][0..4], std.hash.Crc32.hash(copy[offset + 4 ..][0 .. 4 + len]), .big);
    return copy;
}

test "rejects what it can't or shouldn't decode" {
    const good = @embedFile("testdata/png/rgb8.png");
    const a = testing.allocator;
    try testing.expectError(error.NotPng, decode(a, "\xff\xd8\xff\xe0 a JPEG"));
    try testing.expectError(error.NotPng, decode(a, ""));
    try testing.expectError(error.Truncated, decode(a, good[0 .. good.len - 5]));
    try testing.expectError(error.Truncated, decode(a, good[0..40]));

    // A flipped bit in IHDR's data.
    const bad_crc = try a.dupe(u8, good);
    defer a.free(bad_crc);
    bad_crc[8 + 8] ^= 1;
    try testing.expectError(error.BadCrc, decode(a, bad_crc));

    const interlaced = try patched(good, 8, 12, 1);
    defer a.free(interlaced);
    try testing.expectError(error.Unsupported, decode(a, interlaced));

    const bad_depth = try patched(good, 8, 8, 3);
    defer a.free(bad_depth);
    try testing.expectError(error.BadPng, decode(a, bad_depth));

    // 65535 x 65535 claims 4 Gpx.
    const huge = try patched(good, 8, 0, 0xff);
    defer a.free(huge);
    huge[8 + 8 + 1] = 0xff;
    huge[8 + 8 + 2] = 0xff;
    huge[8 + 8 + 3] = 0xff;
    std.mem.writeInt(u32, huge[8 + 8 + 13 ..][0..4], std.hash.Crc32.hash(huge[12..][0..17]), .big);
    try testing.expectError(error.TooLarge, decode(a, huge));

    // A bigger height than the image stream holds.
    const taller = try patched(good, 8, 7, 11);
    defer a.free(taller);
    try testing.expectError(error.Truncated, decode(a, taller));

    // A smaller height leaves image data over.
    const shorter = try patched(good, 8, 7, 9);
    defer a.free(shorter);
    try testing.expectError(error.BadPng, decode(a, shorter));
}

/// A 7x10 RGB8 PNG around `raw` (filter bytes included), stored without compression. With
/// `flushed`, the data block is not final and an empty final stored block follows, as a zlib
/// sync flush before the finish writes it.
fn storedPng(a: Allocator, raw: []const u8, flushed: bool) ![]u8 {
    var png: Io.Writer.Allocating = .init(a);
    errdefer png.deinit();
    const w = &png.writer;
    try w.writeAll(@embedFile("testdata/png/rgb8.png")[0 .. 8 + 25]); // signature + IHDR
    // zlib with one stored deflate block: header, BFINAL+stored, LEN, NLEN, data, Adler-32.
    var z: Io.Writer.Allocating = .init(a);
    defer z.deinit();
    try z.writer.writeAll(if (flushed) "\x78\x01\x00" else "\x78\x01\x01");
    try z.writer.writeInt(u16, @intCast(raw.len), .little);
    try z.writer.writeInt(u16, ~@as(u16, @intCast(raw.len)), .little);
    try z.writer.writeAll(raw);
    if (flushed) try z.writer.writeAll("\x01\x00\x00\xff\xff");
    try z.writer.writeInt(u32, std.hash.Adler32.hash(raw), .big);
    try w.writeInt(u32, @intCast(z.written().len), .big);
    var crc: std.hash.Crc32 = .init();
    crc.update("IDAT");
    crc.update(z.written());
    try w.writeAll("IDAT");
    try w.writeAll(z.written());
    try w.writeInt(u32, crc.final(), .big);
    try w.writeAll("\x00\x00\x00\x00IEND\xae\x42\x60\x82");
    return png.toOwnedSlice();
}

test "a bad filter type is an error, not a crash" {
    const a = testing.allocator;
    var raw: [10 * (1 + 7 * 3)]u8 = @splat(0);
    const ok = try storedPng(a, &raw, false);
    defer a.free(ok);
    const img = try decode(a, ok);
    img.deinit(a);

    raw[0] = 5;
    const bad = try storedPng(a, &raw, false);
    defer a.free(bad);
    try testing.expectError(error.BadPng, decode(a, bad));
}

test "an empty stored block after the last pixel byte (a sync flush) still decodes" {
    const a = testing.allocator;
    var raw: [10 * (1 + 7 * 3)]u8 = @splat(0);
    for (0..10) |y| raw[y * 22 + 1] = @intCast(y * 20);
    const file = try storedPng(a, &raw, true);
    defer a.free(file);
    const img = try decode(a, file);
    defer img.deinit(a);
    try testing.expectEqual([3]u8{ 180, 0, 0 }, img.pixel(0, 9));
}
