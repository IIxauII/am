//! The Apple Music developer token: an ES256 JWT signed with the MusicKit key, and the rules for
//! when a stored one can still be used.
const std = @import("std");
const pkcs8 = @import("pkcs8.zig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Allocator = std.mem.Allocator;

/// The token's `exp - iat`: Apple's maximum of 15 777 000 s minus an hour, because Apple measures
/// the maximum against its own clock and rejects a token that exceeds it.
pub const lifetime_seconds = 15_777_000 - 3600;

const b64 = std.base64.url_safe_no_pad;

/// Signs `{"alg":"ES256","kid":…}.{"iss":…,"iat":…,"exp":…}`. Never add claims: `aud` or `sub`
/// break Apple's sign-in popup. Caller owns the returned token.
pub fn sign(gpa: Allocator, secret_key: Ecdsa.SecretKey, ids: Ids, now: i64, noise: ?[Ecdsa.noise_length]u8) ![]u8 {
    const header = try std.json.Stringify.valueAlloc(gpa, Header{ .alg = "ES256", .kid = ids.key_id }, .{});
    defer gpa.free(header);
    const claims = try std.json.Stringify.valueAlloc(gpa, Claims{ .iss = ids.team_id, .iat = now, .exp = now + lifetime_seconds }, .{});
    defer gpa.free(claims);

    var token: std.Io.Writer.Allocating = .init(gpa);
    errdefer token.deinit();
    try b64.Encoder.encodeWriter(&token.writer, header);
    try token.writer.writeByte('.');
    try b64.Encoder.encodeWriter(&token.writer, claims);

    var key_pair = try Ecdsa.KeyPair.fromSecretKey(secret_key);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key_pair));
    const signature = try key_pair.sign(token.written(), noise);
    try token.writer.writeByte('.');
    try b64.Encoder.encodeWriter(&token.writer, &signature.toBytes());
    return token.toOwnedSlice();
}

// Field order is the order in the JSON.
pub const Header = struct {
    alg: []const u8,
    kid: []const u8,
};

pub const Claims = struct {
    iss: []const u8,
    iat: i64,
    exp: i64,
};

/// The key and team a token must be signed for (from the env file or environment).
pub const Ids = struct {
    team_id: []const u8,
    key_id: []const u8,
};

pub const Status = union(enum) {
    missing,
    /// Signed for another KEY_ID or TEAM_ID: treated as missing.
    mismatch: Decoded,
    expired: Decoded,
    usable: struct { decoded: Decoded, expiring_soon: bool },

    /// The stored token's header and claims, unless there is no readable token.
    pub fn decoded(s: Status) ?Decoded {
        return switch (s) {
            .missing => null,
            .mismatch, .expired => |d| d,
            .usable => |u| u.decoded,
        };
    }
};

pub const warn_days = 14;

/// Whether a stored token can be used `now` (Unix seconds). Allocates into `arena`.
pub fn check(arena: Allocator, stored: ?[]const u8, ids: Ids, now: i64) Allocator.Error!Status {
    const token = decode(arena, stored orelse return .missing) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .missing,
    };
    if (!std.mem.eql(u8, token.header.kid, ids.key_id) or !std.mem.eql(u8, token.claims.iss, ids.team_id)) return .{ .mismatch = token };
    if (token.claims.exp <= now) return .{ .expired = token };
    return .{ .usable = .{ .decoded = token, .expiring_soon = token.claims.exp - now < warn_days * 24 * 3600 } };
}

/// Formats why a `check` result other than `.usable` stops a command.
pub const Problem = struct {
    status: Status,

    pub fn format(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p.status) {
            .missing => try w.writeAll("developer token missing"),
            .mismatch => try w.writeAll("developer token missing (the stored one is for another KEY_ID or TEAM_ID)"),
            .expired => |d| try w.print("developer token expired ({f})", .{UtcTime{ .unix = d.claims.exp }}),
            .usable => unreachable,
        }
        try w.writeAll(": run am token --key-stdin");
    }
};

/// Formats Unix seconds as `2024-05-15 11:43 UTC`.
pub const UtcTime = struct {
    unix: i64,

    pub fn format(t: UtcTime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(t.unix, 0)) };
        const year_day = seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = seconds.getDaySeconds();
        try w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
        });
    }
};

pub const Decoded = struct {
    header: Header,
    claims: Claims,
};

/// Reads a token's header and claims without checking its signature. Allocates into `arena`.
pub fn decode(arena: Allocator, token: []const u8) !Decoded {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header = try decodeJson(Header, arena, parts.next().?);
    const claims = try decodeJson(Claims, arena, parts.next() orelse return error.NotAJwt);
    _ = parts.next() orelse return error.NotAJwt;
    if (parts.next() != null) return error.NotAJwt;
    return .{ .header = header, .claims = claims };
}

fn decodeJson(comptime T: type, arena: Allocator, part: []const u8) !T {
    const json = try arena.alloc(u8, try b64.Decoder.calcSizeForSlice(part));
    try b64.Decoder.decode(json, part);
    return std.json.parseFromSliceLeaky(T, arena, json, .{ .ignore_unknown_fields = true });
}

const testing = std.testing;

fn testKeyPair() !Ecdsa.KeyPair {
    return Ecdsa.KeyPair.fromSecretKey(try pkcs8.parsePem(@embedFile("testkey-p256.p8")));
}

fn decodePart(buf: []u8, part: []const u8) ![]u8 {
    const len = try b64.Decoder.calcSizeForSlice(part);
    try b64.Decoder.decode(buf[0..len], part);
    return buf[0..len];
}

test "signs a JWT with exactly the header and claims Apple expects" {
    const token = try sign(testing.allocator, (try testKeyPair()).secret_key, test_ids, 1_700_000_000, null);
    defer testing.allocator.free(token);

    var parts = std.mem.splitScalar(u8, token, '.');
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"alg\":\"ES256\",\"kid\":\"KEY1234567\"}", try decodePart(&buf, parts.next().?));
    try testing.expectEqualStrings("{\"iss\":\"TEAM123456\",\"iat\":1700000000,\"exp\":1715773400}", try decodePart(&buf, parts.next().?));
    try testing.expectEqual(@as(usize, 86), parts.next().?.len); // 64 raw bytes of r||s, base64url
    try testing.expectEqual(null, parts.next());
}

test "the signature verifies against the key's public key" {
    const key_pair = try testKeyPair();
    var noise: [Ecdsa.noise_length]u8 = undefined;
    testing.io.random(&noise);
    const token = try sign(testing.allocator, key_pair.secret_key, test_ids, 1_700_000_000, noise);
    defer testing.allocator.free(token);

    const dot = std.mem.findScalarLast(u8, token, '.').?;
    var sig: [Ecdsa.Signature.encoded_length]u8 = undefined;
    try b64.Decoder.decode(&sig, token[dot + 1 ..]);
    const public_key = try Ecdsa.PublicKey.fromSec1(@embedFile("testkey-p256.pub.der")[26..]);
    try Ecdsa.Signature.fromBytes(sig).verify(token[0..dot], public_key);

    var tampered = sig;
    tampered[10] ^= 1;
    try testing.expectError(error.SignatureVerificationFailed, Ecdsa.Signature.fromBytes(tampered).verify(token[0..dot], public_key));
}

fn testToken(team_id: []const u8, key_id: []const u8, iat: i64) ![]u8 {
    return sign(testing.allocator, (try testKeyPair()).secret_key, .{ .team_id = team_id, .key_id = key_id }, iat, null);
}

const day = 24 * 3600;

const test_ids: Ids = .{ .team_id = "TEAM123456", .key_id = "KEY1234567" };
const exp = 1_715_773_400;

fn expectStatus(expected: std.meta.Tag(Status), expiring_soon: ?bool, stored: ?[]const u8, with: Ids, now: i64) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const status = try check(arena.allocator(), stored, with, now);
    try testing.expectEqual(expected, std.meta.activeTag(status));
    if (expiring_soon) |soon| try testing.expectEqual(soon, status.usable.expiring_soon);
    if (status.decoded()) |d| {
        // Whatever the verdict, the token's own fields are reported.
        try testing.expectEqualStrings("KEY1234567", d.header.kid);
        try testing.expectEqualStrings("TEAM123456", d.claims.iss);
        try testing.expectEqual(@as(i64, exp), d.claims.exp);
    }
}

test "a stored token is usable while it matches the env and hasn't expired" {
    const token = try testToken("TEAM123456", "KEY1234567", 1_700_000_000);
    defer testing.allocator.free(token);
    try expectStatus(.usable, false, token, test_ids, 1_700_000_000 + 30 * day);
}

test "no stored token, or one that isn't a JWT, is missing" {
    try expectStatus(.missing, null, null, test_ids, 0);
    try expectStatus(.missing, null, "", test_ids, 0);
    try expectStatus(.missing, null, "not a token", test_ids, 0);
    try expectStatus(.missing, null, "e30.e30.", test_ids, 0); // {}.{}
}

test "a stored token for another kid or iss is treated as missing" {
    const token = try testToken("TEAM123456", "KEY1234567", 1_700_000_000);
    defer testing.allocator.free(token);
    const now = 1_700_000_000 + day;
    try expectStatus(.mismatch, null, token, .{ .team_id = "TEAM123456", .key_id = "OTHERKEY00" }, now);
    try expectStatus(.mismatch, null, token, .{ .team_id = "OTHERTEAM0", .key_id = "KEY1234567" }, now);
}

test "a stored token is expired from its exp on" {
    const token = try testToken("TEAM123456", "KEY1234567", 1_700_000_000);
    defer testing.allocator.free(token);
    try expectStatus(.expired, null, token, test_ids, exp);
    try expectStatus(.usable, true, token, test_ids, exp - 1);
}

test "the warning starts when fewer than 14 days are left" {
    const token = try testToken("TEAM123456", "KEY1234567", 1_700_000_000);
    defer testing.allocator.free(token);
    try expectStatus(.usable, false, token, test_ids, exp - 14 * day);
    try expectStatus(.usable, true, token, test_ids, exp - 14 * day + 1);
}

test "running out of memory while checking is an error, not a missing token" {
    const token = try testToken("TEAM123456", "KEY1234567", 1_700_000_000);
    defer testing.allocator.free(token);
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, check(failing.allocator(), token, test_ids, 0));
}

fn renderProblem(buf: []u8, status: Status) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{f}", .{Problem{ .status = status }});
    return w.buffered();
}

test "commands that need the token say why it can't be used and how to fix it" {
    var buf: [200]u8 = undefined;
    const decoded: Decoded = .{ .header = .{ .alg = "ES256", .kid = "KEY1234567" }, .claims = .{ .iss = "TEAM123456", .iat = exp - lifetime_seconds, .exp = exp } };
    try testing.expectEqualStrings("developer token missing: run am token --key-stdin", try renderProblem(&buf, .missing));
    try testing.expectEqualStrings("developer token missing (the stored one is for another KEY_ID or TEAM_ID): run am token --key-stdin", try renderProblem(&buf, .{ .mismatch = decoded }));
    try testing.expectEqualStrings("developer token expired (2024-05-15 11:43 UTC): run am token --key-stdin", try renderProblem(&buf, .{ .expired = decoded }));
}
