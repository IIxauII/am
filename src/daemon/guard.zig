//! Who may talk to the background process's server. Every request passes the Host and Origin
//! checks; CLI requests also carry the daemon secret. The server never sends CORS headers, so a
//! web page in the user's normal browser can neither send commands nor read responses.
const std = @import("std");

/// Header carrying the contents of `<config dir>/daemon-secret` on CLI requests.
pub const secret_header = "X-AM-Secret";
/// Header naming the client (a TUI session) a CLI request comes from, when it says.
pub const client_header = "X-AM-Client";

/// Protection against DNS rebinding: only loopback host names, on our port.
pub fn hostAllowed(host: ?[]const u8, port: u16) bool {
    const h = host orelse return false;
    const colon = std.mem.findScalarLast(u8, h, ':') orelse return false;
    if (!isLoopbackName(h[0..colon])) return false;
    const given = std.fmt.parseInt(u16, h[colon + 1 ..], 10) catch return false;
    return given == port;
}

/// A request without an Origin header passes (the CLI, and the page's same-origin GETs). With one,
/// it must be one of our own loopback origins: otherwise any website open in the user's browser
/// could POST a Music User Token, or open the report socket (WebSockets ignore CORS) and send fake
/// reports.
pub fn originAllowed(origin: ?[]const u8, port: u16) bool {
    const o = origin orelse return true;
    const prefix = "http://";
    if (!std.mem.startsWith(u8, o, prefix)) return false;
    return hostAllowed(o[prefix.len..], port);
}

/// Compares in constant time, so the secret can't be guessed byte by byte from response timings.
pub fn secretMatches(expected: []const u8, given: ?[]const u8) bool {
    const g = given orelse return false;
    if (expected.len == 0 or g.len != expected.len) return false;
    var diff: u8 = 0;
    for (expected, g) |a, b| diff |= a ^ b;
    return diff == 0;
}

fn isLoopbackName(name: []const u8) bool {
    return std.mem.eql(u8, name, "localhost") or std.mem.eql(u8, name, "127.0.0.1") or std.mem.eql(u8, name, "[::1]");
}

const testing = std.testing;

test "the Host must be localhost, 127.0.0.1 or [::1] with our port" {
    try testing.expect(hostAllowed("localhost:47823", 47823));
    try testing.expect(hostAllowed("127.0.0.1:47823", 47823));
    try testing.expect(hostAllowed("[::1]:47823", 47823));

    try testing.expect(!hostAllowed(null, 47823));
    try testing.expect(!hostAllowed("evil.example", 47823));
    try testing.expect(!hostAllowed("evil.example:47823", 47823));
    // DNS rebinding names that merely start or end like a loopback name.
    try testing.expect(!hostAllowed("localhost.evil.example:47823", 47823));
    try testing.expect(!hostAllowed("evil-localhost:47823", 47823));
    try testing.expect(!hostAllowed("127.0.0.1.evil.example:47823", 47823));
    // No port, another port, or junk after the colon.
    try testing.expect(!hostAllowed("localhost", 47823));
    try testing.expect(!hostAllowed("localhost:", 47823));
    try testing.expect(!hostAllowed("localhost:8080", 47823));
    try testing.expect(!hostAllowed("localhost:47823x", 47823));
    try testing.expect(!hostAllowed("::1:47823", 47823));
    try testing.expect(!hostAllowed("LOCALHOST:47823", 47823));
}

test "an Origin header must be one of our loopback origins; none at all is fine" {
    try testing.expect(originAllowed(null, 47823));
    try testing.expect(originAllowed("http://localhost:47823", 47823));
    try testing.expect(originAllowed("http://127.0.0.1:47823", 47823));
    try testing.expect(originAllowed("http://[::1]:47823", 47823));

    try testing.expect(!originAllowed("https://evil.example", 47823));
    try testing.expect(!originAllowed("http://evil.example:47823", 47823));
    try testing.expect(!originAllowed("https://localhost:47823", 47823));
    try testing.expect(!originAllowed("http://localhost:8080", 47823));
    try testing.expect(!originAllowed("http://localhost:47823/", 47823));
    try testing.expect(!originAllowed("null", 47823));
    try testing.expect(!originAllowed("", 47823));
}

test "the secret must be present and match exactly" {
    const secret = "0123456789abcdef0123456789abcdef";
    try testing.expect(secretMatches(secret, "0123456789abcdef0123456789abcdef"));
    try testing.expect(!secretMatches(secret, null));
    try testing.expect(!secretMatches(secret, ""));
    try testing.expect(!secretMatches(secret, "0123456789abcdef0123456789abcdee"));
    try testing.expect(!secretMatches(secret, "0123456789abcdef"));
    try testing.expect(!secretMatches(secret, "0123456789abcdef0123456789abcdef0"));
    // A daemon without a secret accepts nobody.
    try testing.expect(!secretMatches("", ""));
}
