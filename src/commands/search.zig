//! `am search <term>`: catalog search over the REST API, no engine.
const std = @import("std");
const apple = @import("../apple.zig");
const commands = @import("../commands.zig");

const Context = commands.Context;

pub fn run(ctx: *const Context, term: []const u8) !void {
    var renewer = ctx.tokenRenewer();
    const client: apple.Client = .{
        .transport = ctx.apple_transport,
        .developer_token = try ctx.developerToken(),
        .user_token = try ctx.userToken(),
        .renew = renewer.renew(),
    };
    const store = apple.storefront(client, ctx.arena) catch |e| return ctx.fail("search failed: {t}", .{e});
    const result = apple.searchSongs(client, ctx.arena, store, term, 5) catch |e| return ctx.fail("search failed: {t}", .{e});
    switch (result) {
        .failed => |response| {
            const body = response.excerpt(300);
            return ctx.fail("search failed: HTTP {d}{s}{s}", .{ response.status, if (body.len > 0) " " else "", body });
        },
        .songs => |songs| {
            if (songs.len == 0) try ctx.out.print("no songs found for \"{s}\" [{s}]\n", .{ term, store });
            for (songs) |song| try apple.writeSongLine(ctx.out, song);
        },
    }
}
