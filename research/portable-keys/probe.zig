//! Feeds byte sequences terminals send to am's decoder (input.zig at origin/main 31a0ddf)
//! and prints the key it decodes and what keys.command / keys.textCommand make of it.
const std = @import("std");
const input = @import("input.zig");
const keys = @import("keys.zig");

const Case = struct { label: []const u8, bytes: []const u8 };

const cases = [_]Case{
    // Plain, composed, Alt as ESC prefix
    .{ .label = "a", .bytes = "a" },
    .{ .label = "Shift+a", .bytes = "A" },
    .{ .label = "Option+f composed (US)", .bytes = "\u{0192}" },
    .{ .label = "Option+a composed (US)", .bytes = "\u{00e5}" },
    .{ .label = "Option+5 composed (German: [)", .bytes = "[" },
    .{ .label = "Alt+a (ESC prefix)", .bytes = "\x1ba" },
    .{ .label = "Alt+Shift+a (ESC prefix)", .bytes = "\x1bA" },
    .{ .label = "Alt+1", .bytes = "\x1b1" },
    .{ .label = "Alt+[ alone (flushed)", .bytes = "\x1b[" },
    .{ .label = "Alt+[ then A within 30 ms", .bytes = "\x1b[A" },
    .{ .label = "Alt+O then P within 30 ms", .bytes = "\x1bOP" },
    .{ .label = "Alt+Shift+O alone (flushed)", .bytes = "\x1bO" },
    .{ .label = "Alt+_ alone (flushed)", .bytes = "\x1b_" },
    .{ .label = "Alt+Esc", .bytes = "\x1b\x1b" },
    .{ .label = "Alt+a 8-bit meta (xterm eightBitInput)", .bytes = "\xe1" },
    .{ .label = "Alt+a 8-bit meta, UTF-8 encoded", .bytes = "\xc3\xa1" },
    .{ .label = "xterm Alt+Backspace (U+0088)", .bytes = "\xc2\x88" },
    .{ .label = "xterm Alt+Esc (U+009B)", .bytes = "\xc2\x9b" },
    .{ .label = "Konsole Super+a", .bytes = "\x18@sa" },
    .{ .label = "Konsole Super+Up", .bytes = "\x1b[1;1A" },
    // C0 controls: the legacy collisions
    .{ .label = "0x00 (Ctrl+Space, Ctrl+@, Ctrl+2)", .bytes = "\x00" },
    .{ .label = "0x08 (Ctrl+h, Ctrl+Backspace, BS key)", .bytes = "\x08" },
    .{ .label = "0x09 (Tab, Ctrl+i)", .bytes = "\x09" },
    .{ .label = "0x0a (Ctrl+j, LF)", .bytes = "\x0a" },
    .{ .label = "0x0d (Enter, Ctrl+m)", .bytes = "\x0d" },
    .{ .label = "0x1b alone (Esc, Ctrl+[, Ctrl+3)", .bytes = "\x1b" },
    .{ .label = "0x1c (Ctrl+\\, Ctrl+4)", .bytes = "\x1c" },
    .{ .label = "0x1d (Ctrl+], Ctrl+5)", .bytes = "\x1d" },
    .{ .label = "0x1e (Ctrl+^, Ctrl+6)", .bytes = "\x1e" },
    .{ .label = "0x1f (Ctrl+/, Ctrl+_, Ctrl+7, Ctrl+-)", .bytes = "\x1f" },
    .{ .label = "0x7f (Backspace, Ctrl+8, Ctrl+?)", .bytes = "\x7f" },
    .{ .label = "0x17 (Ctrl+w; some send for Ctrl+Backspace)", .bytes = "\x17" },
    .{ .label = "0x03 (Ctrl+c)", .bytes = "\x03" },
    .{ .label = "0x1a (Ctrl+z)", .bytes = "\x1a" },
    .{ .label = "Alt+Backspace", .bytes = "\x1b\x7f" },
    .{ .label = "Alt+Ctrl+h / Alt+Ctrl+Backspace", .bytes = "\x1b\x08" },
    .{ .label = "Ctrl+Alt+a", .bytes = "\x1b\x01" },
    // Named keys, legacy forms
    .{ .label = "Up (normal mode)", .bytes = "\x1b[A" },
    .{ .label = "Up (application mode)", .bytes = "\x1bOA" },
    .{ .label = "Shift+Up", .bytes = "\x1b[1;2A" },
    .{ .label = "Alt+Up", .bytes = "\x1b[1;3A" },
    .{ .label = "Ctrl+Up", .bytes = "\x1b[1;5A" },
    .{ .label = "Ctrl+Shift+Up", .bytes = "\x1b[1;6A" },
    .{ .label = "Meta+Up (xterm 9)", .bytes = "\x1b[1;9A" },
    .{ .label = "Shift+Left", .bytes = "\x1b[1;2D" },
    .{ .label = "Alt+Left (ESC ESC [ D)", .bytes = "\x1b\x1b[D" },
    .{ .label = "Option+Left (Terminal.app ESC b)", .bytes = "\x1bb" },
    .{ .label = "Option+Right (Terminal.app ESC f)", .bytes = "\x1bf" },
    .{ .label = "Home CSI H", .bytes = "\x1b[H" },
    .{ .label = "Home SS3 H", .bytes = "\x1bOH" },
    .{ .label = "Home CSI 1~", .bytes = "\x1b[1~" },
    .{ .label = "Home CSI 7~ (rxvt)", .bytes = "\x1b[7~" },
    .{ .label = "End CSI F", .bytes = "\x1b[F" },
    .{ .label = "End CSI 4~", .bytes = "\x1b[4~" },
    .{ .label = "Shift+Home", .bytes = "\x1b[1;2H" },
    .{ .label = "Insert", .bytes = "\x1b[2~" },
    .{ .label = "Delete", .bytes = "\x1b[3~" },
    .{ .label = "Shift+Delete", .bytes = "\x1b[3;2~" },
    .{ .label = "PgUp", .bytes = "\x1b[5~" },
    .{ .label = "Shift+PgUp", .bytes = "\x1b[5;2~" },
    .{ .label = "F1 SS3", .bytes = "\x1bOP" },
    .{ .label = "F1 CSI 11~", .bytes = "\x1b[11~" },
    .{ .label = "F1 linux console", .bytes = "\x1b[[A" },
    .{ .label = "F3 SS3", .bytes = "\x1bOR" },
    .{ .label = "F5", .bytes = "\x1b[15~" },
    .{ .label = "F12", .bytes = "\x1b[24~" },
    .{ .label = "Shift+F1 xterm", .bytes = "\x1b[1;2P" },
    .{ .label = "Shift+F1 SS3 2P (old Konsole/xterm)", .bytes = "\x1bO2P" },
    .{ .label = "Ctrl+F1 Konsole", .bytes = "\x1bO5P" },
    .{ .label = "Shift+F3 Konsole", .bytes = "\x1bO2R" },
    .{ .label = "Shift+F3 xterm", .bytes = "\x1b[1;2R" },
    .{ .label = "Ctrl+F3 xterm", .bytes = "\x1b[1;5R" },
    .{ .label = "Shift+F5", .bytes = "\x1b[15;2~" },
    .{ .label = "F13 (CSI 25~)", .bytes = "\x1b[25~" },
    .{ .label = "Shift+F1 as F11 (VT220 shifted)", .bytes = "\x1b[23~" },
    .{ .label = "Shift+Tab", .bytes = "\x1b[Z" },
    .{ .label = "Keypad Enter (application keypad)", .bytes = "\x1bOM" },
    // kitty keyboard protocol, flag 1 (disambiguate)
    .{ .label = "kitty Esc", .bytes = "\x1b[27u" },
    .{ .label = "kitty Ctrl+i", .bytes = "\x1b[105;5u" },
    .{ .label = "kitty Ctrl+h", .bytes = "\x1b[104;5u" },
    .{ .label = "kitty Ctrl+m", .bytes = "\x1b[109;5u" },
    .{ .label = "kitty Ctrl+j", .bytes = "\x1b[106;5u" },
    .{ .label = "kitty Ctrl+[", .bytes = "\x1b[91;5u" },
    .{ .label = "kitty Ctrl+Space", .bytes = "\x1b[32;5u" },
    .{ .label = "kitty Ctrl+c", .bytes = "\x1b[99;5u" },
    .{ .label = "kitty Ctrl+z", .bytes = "\x1b[122;5u" },
    .{ .label = "kitty Ctrl+Shift+a", .bytes = "\x1b[97;6u" },
    .{ .label = "kitty Alt+a", .bytes = "\x1b[97;3u" },
    .{ .label = "kitty Alt+Shift+a", .bytes = "\x1b[97;4u" },
    .{ .label = "kitty Alt+Shift+a, flag 4 alternate", .bytes = "\x1b[97:65;4u" },
    .{ .label = "kitty Ctrl+1", .bytes = "\x1b[49;5u" },
    .{ .label = "kitty Ctrl+2", .bytes = "\x1b[50;5u" },
    .{ .label = "kitty Ctrl+3", .bytes = "\x1b[51;5u" },
    .{ .label = "kitty Ctrl+8", .bytes = "\x1b[56;5u" },
    .{ .label = "kitty Alt+[", .bytes = "\x1b[91;3u" },
    .{ .label = "kitty Ctrl+Shift+3 (legacy mode too)", .bytes = "\x1b[51;6u" },
    .{ .label = "kitty Ctrl+/", .bytes = "\x1b[47;5u" },
    .{ .label = "kitty Shift+Enter", .bytes = "\x1b[13;2u" },
    .{ .label = "kitty Ctrl+Enter", .bytes = "\x1b[13;5u" },
    .{ .label = "kitty Shift+Space (flag 8 only)", .bytes = "\x1b[32;2u" },
    .{ .label = "kitty Shift+Backspace", .bytes = "\x1b[127;2u" },
    .{ .label = "kitty Ctrl+Backspace", .bytes = "\x1b[127;5u" },
    .{ .label = "kitty Shift+Tab", .bytes = "\x1b[9;2u" },
    .{ .label = "kitty Ctrl+Tab", .bytes = "\x1b[9;5u" },
    .{ .label = "kitty Super+a (Cmd)", .bytes = "\x1b[97;9u" },
    .{ .label = "kitty Hyper+a", .bytes = "\x1b[97;17u" },
    .{ .label = "kitty Meta+a (bit 32)", .bytes = "\x1b[97;33u" },
    .{ .label = "kitty Ctrl+a, Caps Lock on", .bytes = "\x1b[97;69u" },
    .{ .label = "kitty Ctrl+a, Num Lock on", .bytes = "\x1b[97;133u" },
    .{ .label = "kitty Ctrl+Up", .bytes = "\x1b[1;5A" },
    .{ .label = "kitty F3", .bytes = "\x1b[13~" },
    .{ .label = "kitty F13", .bytes = "\x1b[57376u" },
    .{ .label = "kitty KP_Enter", .bytes = "\x1b[57414u" },
    .{ .label = "kitty KP_1", .bytes = "\x1b[57400u" },
    .{ .label = "kitty KP_Up", .bytes = "\x1b[57419u" },
    .{ .label = "kitty Menu", .bytes = "\x1b[57363u" },
    .{ .label = "kitty Media play/pause", .bytes = "\x1b[57430u" },
    .{ .label = "kitty Ctrl+ä (German, U+00E4)", .bytes = "\x1b[228;5u" },
    // xterm modifyOtherKeys, mode 2, formatOtherKeys 0 and 1
    .{ .label = "mOK Ctrl+a", .bytes = "\x1b[27;5;97~" },
    .{ .label = "mOK Ctrl+Shift+a (code 65)", .bytes = "\x1b[27;6;65~" },
    .{ .label = "mOK Ctrl+Shift+a (code 97)", .bytes = "\x1b[27;6;97~" },
    .{ .label = "mOK Ctrl+i", .bytes = "\x1b[27;5;105~" },
    .{ .label = "mOK Ctrl+h", .bytes = "\x1b[27;5;104~" },
    .{ .label = "mOK Ctrl+m", .bytes = "\x1b[27;5;109~" },
    .{ .label = "mOK Ctrl+[", .bytes = "\x1b[27;5;91~" },
    .{ .label = "mOK Ctrl+Space", .bytes = "\x1b[27;5;32~" },
    .{ .label = "mOK Shift+Enter", .bytes = "\x1b[27;2;13~" },
    .{ .label = "mOK Ctrl+Enter", .bytes = "\x1b[27;5;13~" },
    .{ .label = "mOK Shift+Space", .bytes = "\x1b[27;2;32~" },
    .{ .label = "mOK Alt+a", .bytes = "\x1b[27;3;97~" },
    .{ .label = "mOK Ctrl+1", .bytes = "\x1b[27;5;49~" },
    .{ .label = "mOK Ctrl+Tab", .bytes = "\x1b[27;5;9~" },
    .{ .label = "mOK Ctrl+Backspace", .bytes = "\x1b[27;5;127~" },
    .{ .label = "mOK Ctrl+Backspace (code 8)", .bytes = "\x1b[27;5;8~" },
    .{ .label = "mOK fmt1 Ctrl+Shift+a", .bytes = "\x1b[65;6u" },
    .{ .label = "mOK Ctrl+Shift+a, Shift dropped (WezTerm)", .bytes = "\x1b[27;5;65~" },
    .{ .label = "Ghostty legacy Super+Enter", .bytes = "\x1b[27;9;13~" },
    .{ .label = "Ghostty legacy Ctrl+;", .bytes = "\x1b[59;5u" },
    .{ .label = "foot legacy Ctrl+1", .bytes = "\x1b[27;5;49~" },
    // Windows Terminal win32-input-mode (only if an app asks for it)
    .{ .label = "win32-input-mode 'a' down", .bytes = "\x1b[65;30;97;1;0;1_" },
    // Replies am may get mixed in
    .{ .label = "kitty flags reply CSI ? 1 u", .bytes = "\x1b[?1u" },
    .{ .label = "XTQMODKEYS reply CSI > 4;2 m", .bytes = "\x1b[>4;2m" },
};

fn describeKey(w: *std.Io.Writer, k: input.Key) !void {
    if (k.ctrl) try w.writeAll("ctrl+");
    if (k.alt) try w.writeAll("alt+");
    if (k.shift) try w.writeAll("shift+");
    switch (k.code) {
        .char => |c| if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) try w.print("U+{X:0>4}", .{c}) else if (c >= 0xe000 and c <= 0xf8ff) try w.print("char(U+{X:0>4} private use)", .{c}) else try w.print("'{u}'", .{c}),
        .f => |n| try w.print("F{d}", .{n}),
        else => try w.writeAll(@tagName(k.code)),
    }
}

fn describeCommand(w: *std.Io.Writer, c: ?keys.Command) !void {
    const cmd = c orelse return w.writeAll("-");
    switch (cmd) {
        inline else => |v, tag| {
            if (@TypeOf(v) == void) return w.writeAll(@tagName(tag));
            if (@TypeOf(v) == keys.Section) return w.print("{s}={s}", .{ @tagName(tag), @tagName(v) });
            return w.print("{s}={d}", .{ @tagName(tag), v });
        },
    }
}

fn describeText(w: *std.Io.Writer, c: ?keys.TextCommand) !void {
    const cmd = c orelse return w.writeAll("-");
    switch (cmd) {
        .insert => |cp| if ((cp >= 0x7f and cp <= 0x9f) or (cp >= 0xe000 and cp <= 0xf8ff)) try w.print("insert U+{X:0>4}", .{cp}) else try w.print("insert '{u}'", .{cp}),
        else => try w.writeAll(@tagName(cmd)),
    }
}

fn escaped(w: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |b| switch (b) {
        0x1b => try w.writeAll("\\e"),
        0x20...0x5b, 0x5d...0x7e => try w.writeByte(b),
        else => try w.print("\\x{x:0>2}", .{b}),
    };
}

test "probe" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("| Key | Bytes | am decodes | `command` (lists) | `textCommand` (typing) |\n|---|---|---|---|---|\n");
    for (cases) |case| {
        var d: input.Decoder = .init(gpa);
        defer d.deinit();
        try d.feed(case.bytes);
        var events: [16]input.Event = undefined;
        var n: usize = 0;
        while (d.next()) |e| : (n += 1) events[n] = e;
        while (d.flushPending()) |e| : (n += 1) events[n] = e;
        try w.print("| {s} | `", .{case.label});
        try escaped(w, case.bytes);
        try w.writeAll("` | ");
        if (n == 0) try w.writeAll("(nothing)");
        for (events[0..n], 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            switch (e) {
                .key => |k| try describeKey(w, k),
                else => try w.print("({s})", .{@tagName(e)}),
            }
        }
        try w.writeAll(" | ");
        for (events[0..n], 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            switch (e) {
                .key => |k| try describeCommand(w, keys.command(k)),
                else => try w.writeAll("-"),
            }
        }
        try w.writeAll(" | ");
        for (events[0..n], 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            switch (e) {
                .key => |k| try describeText(w, keys.textCommand(k)),
                else => try w.writeAll("-"),
            }
        }
        try w.writeAll(" |\n");
    }
    std.debug.print("{s}", .{out.written()});
}
