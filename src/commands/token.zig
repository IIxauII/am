//! `am token [--key-stdin]`: sign the developer token from the `.p8` on stdin, or report the one
//! in use (your own, else the shared one, `token_source.zig`); then test it against Apple. The
//! key itself is never written anywhere.
const std = @import("std");
const apple = @import("../apple.zig");
const commands = @import("../commands.zig");
const config = @import("../config.zig");
const developer_token = @import("../developer_token.zig");
const pkcs8 = @import("../pkcs8.zig");
const platform = @import("../platform.zig");
const token_source = @import("../token_source.zig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Context = commands.Context;
const Io = std.Io;
const UtcTime = developer_token.UtcTime;

pub fn run(ctx: *const Context, key_stdin: bool) !void {
    if (key_stdin) return signAndTest(ctx);

    const found = switch (try ctx.developerTokenSource()) {
        .found => |f| f,
        .problem => |p| return ctx.fail("{s}", .{p.text}),
    };
    try ctx.out.print("developer token: {f}\n", .{found});
    if (found.expiring_soon) {
        const days = @divFloor(found.decoded.claims.exp - ctx.now(), 24 * 3600);
        try ctx.out.print("warning: the developer token expires in {d} days: run am token --key-stdin\n", .{days});
    }
    if (found.refresh_failed) |why|
        try ctx.out.print("warning: can't download a newer shared developer token ({s}); the stored one still works\n", .{why});
    if (found.own_problem) |why|
        try ctx.out.print("warning: your own developer token isn't used ({s}); the shared one is\n", .{why});
    try ctx.out.flush();
    // A shared token Apple refuses (its service's key changed) is renewed once, the way every
    // request does it (`apple.Client`).
    var renewer = ctx.tokenRenewer();
    if (try testWithApple(ctx, found.token, &renewer) != 200) return error.Reported;
}

fn signAndTest(ctx: *const Context) !void {
    const token = try signFromStdin(ctx, try ctx.ids());
    const decoded = try developer_token.decode(ctx.arena, token);
    try platform.writePrivateFile(ctx.io, ctx.config_dir, config.file.developer_token, try std.mem.concat(ctx.arena, u8, &.{ token, "\n" }));
    try ctx.out.print("developer token signed: kid={s} iss={s} expires {f}\nsaved to {s}\n", .{
        decoded.header.kid, decoded.claims.iss, UtcTime{ .unix = decoded.claims.exp }, try ctx.configPath(config.file.developer_token),
    });
    try ctx.out.flush();
    if (try testWithApple(ctx, token, null) != 200) return error.Reported;
}

/// Reads the PEM from stdin, signs, and zeroes every copy of the key it made.
fn signFromStdin(ctx: *const Context, ids: developer_token.Ids) ![]const u8 {
    const stdin = Io.File.stdin();
    if (try stdin.isTty(ctx.io)) return ctx.fail("--key-stdin reads the .p8 from stdin: pipe it in, e.g. from your password manager", .{});

    var read_buffer: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var pem_buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &pem_buffer);
    var reader = stdin.readerStreaming(ctx.io, &read_buffer);
    const len = reader.interface.readSliceShort(&pem_buffer) catch return ctx.fail("can't read the key from stdin", .{});
    if (len == pem_buffer.len) return ctx.fail("stdin holds more than a .p8 key ({d} bytes or more)", .{pem_buffer.len});
    const pem = config.trimSpace(pem_buffer[0..len]);
    if (pem.len == 0) return ctx.fail("stdin is empty: pipe the .p8 in, e.g. from your password manager", .{});

    var secret_key = pkcs8.parsePem(pem) catch |e| return ctx.fail("the key on stdin is {s}", .{pkcs8.describe(e)});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&secret_key));
    var noise: [Ecdsa.noise_length]u8 = undefined;
    ctx.io.random(&noise);
    return developer_token.sign(ctx.arena, secret_key, ids, ctx.now(), noise);
}

/// `GET /v1/test` is uncached; some catalog endpoints answer 200 from Apple's CDN even without a
/// token. With `renewer`, a 401 gets a newer token once, and what the renewal did is printed.
/// Prints Apple's verdict and returns its status.
fn testWithApple(ctx: *const Context, token: []const u8, renewer: ?*token_source.Renewer) !u16 {
    const client: apple.Client = .{
        .transport = ctx.apple_transport,
        .developer_token = token,
        .user_token = null,
        .renew = if (renewer) |r| r.renew() else null,
    };
    const answer = client.getWith(ctx.arena, "/v1/test", .{ .send_user_token = false }) catch |e|
        return ctx.fail("can't reach {s}: {t}", .{ apple.base_url, e });
    if (renewer) |r| if (r.last) |outcome| {
        try ctx.out.print("Apple refused the developer token (HTTP 401): {f}\n", .{outcome});
        if (!std.mem.eql(u8, answer.developer_token, token)) {
            const decoded = try developer_token.decode(ctx.arena, answer.developer_token);
            try ctx.out.print("developer token now: kid={s} iss={s} expires {f}\n", .{ decoded.header.kid, decoded.claims.iss, UtcTime{ .unix = decoded.claims.exp } });
        }
    };
    const response = answer.response;
    if (response.status == 200) {
        try ctx.out.print("✔ Apple accepted the token (GET /v1/test → HTTP {d})\n", .{response.status});
        return response.status;
    }
    try ctx.out.print("✘ Apple rejected the token (GET /v1/test → HTTP {d})\n", .{response.status});
    const body = response.excerpt(500);
    if (body.len > 0) try ctx.out.print("{s}\n", .{body});
    try ctx.out.flush();
    return response.status;
}
