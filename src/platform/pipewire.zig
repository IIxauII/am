//! Linux part of the POSIX backend's `engineAudio`: the engine's streams as PipeWire (through
//! its PulseAudio layer) lists them. Only metadata: Apple's terms forbid measuring or
//! monitoring the audio itself.
const std = @import("std");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Audio = platform.EngineAudio;

/// Runs `pactl -f json list sink-inputs` and keeps the streams of `pids` (the engine tree), so
/// streams of the user's own browser are ignored. Allocates into `arena`.
pub fn engineStreams(arena: Allocator, io: Io, pids: []const platform.ProcessId) Allocator.Error!Audio {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "pactl", "-f", "json", "list", "sink-inputs" },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(64 << 10),
    }) catch |e| return .{ .failed = try arena.print("pactl: {t}", .{e}) };
    if (!result.term.success()) return .{ .failed = try arena.print("pactl exited with {f}: {s}", .{ result.term, std.mem.trim(u8, result.stderr, " \n") }) };
    return parseSinkInputs(arena, result.stdout, pids) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Malformed => .{ .failed = "pactl printed something other than a JSON list" },
    };
}

pub fn parseSinkInputs(arena: Allocator, json: []const u8, pids: []const platform.ProcessId) error{ OutOfMemory, Malformed }!Audio {
    const SinkInput = struct {
        index: u64 = 0,
        sink: u64 = 0,
        corked: bool = false,
        mute: bool = false,
        properties: std.json.ArrayHashMap([]const u8) = .{},
    };
    const inputs = std.json.parseFromSliceLeaky([]const std.json.Value, arena, json, .{}) catch return error.Malformed;
    var streams: std.ArrayList(platform.AudioStream) = .empty;
    for (inputs) |value| {
        // Properties hold strings only; anything else about a stream that doesn't parse is skipped.
        const input = std.json.parseFromValueLeaky(SinkInput, arena, value, .{ .ignore_unknown_fields = true }) catch continue;
        const pid_text = input.properties.map.get("application.process.id") orelse continue;
        const pid = std.fmt.parseInt(platform.ProcessId, pid_text, 10) catch continue;
        if (std.mem.findScalar(platform.ProcessId, pids, pid) == null) continue;
        try streams.append(arena, .{
            .index = input.index,
            .app = input.properties.map.get("application.name") orelse "",
            .media = input.properties.map.get("media.name") orelse "",
            .corked = input.corked,
            .mute = input.mute,
            .sink = input.sink,
        });
    }
    return .{ .streams = streams.items };
}

const testing = std.testing;

test "only the engine tree's sink inputs count, with their state and names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The shape of `pactl -f json list sink-inputs`, shortened.
    const json =
        \\[{"index":81,"driver":"PipeWire","owner_module":"n/a","client":"80","sink":56,"sample_specification":"float32le 2ch 48000Hz",
        \\  "corked":false,"mute":false,"volume":{"front-left":{"value":65536,"value_percent":"100%","db":"0.00 dB"}},
        \\  "properties":{"application.name":"Firefox","application.process.id":"4243","media.name":"AudioStream"}},
        \\ {"index":82,"sink":56,"corked":true,"mute":false,
        \\  "properties":{"application.name":"Firefox","application.process.id":"999","media.name":"YouTube"}},
        \\ {"index":83,"sink":56,"corked":false,"mute":false,"properties":{"application.name":"no pid"}}]
    ;
    const audio = try parseSinkInputs(arena.allocator(), json, &.{ 4242, 4243 });
    try testing.expectEqualDeep(@as([]const platform.AudioStream, &.{
        .{ .index = 81, .app = "Firefox", .media = "AudioStream", .corked = false, .mute = false, .sink = 56 },
    }), audio.streams);
    try testing.expectError(error.Malformed, parseSinkInputs(arena.allocator(), "Connection failure", &.{}));
}
