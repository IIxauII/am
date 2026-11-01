//! Reads the MusicKit `.p8` key: a PEM "PRIVATE KEY" block holding a PKCS#8 PrivateKeyInfo with
//! a P-256 ECPrivateKey inside. std has no PEM or PKCS#8 helper, so this is a small DER walk.
const std = @import("std");
const asn1 = std.crypto.codecs.asn1;

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Error = error{
    /// No `-----BEGIN PRIVATE KEY-----` block, or its body isn't base64.
    NotPem,
    /// The DER inside isn't a PKCS#8 PrivateKeyInfo with an ECPrivateKey.
    NotPkcs8,
    /// A PKCS#8 key, but not an elliptic-curve one (RSA, Ed25519, ...).
    NotEcKey,
    /// An elliptic-curve key on a curve other than P-256.
    NotP256,
    /// The scalar is zero or not below the group order.
    InvalidScalar,
};

/// Describes a parse error for the user.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.NotPem => "not a PEM \"PRIVATE KEY\" block (expected the .p8 file Apple issued)",
        error.NotPkcs8 => "not a PKCS#8 elliptic-curve private key",
        error.NotEcKey => "not an elliptic-curve key (MusicKit keys are P-256)",
        error.NotP256 => "an elliptic-curve key, but not on P-256",
        error.InvalidScalar => "the P-256 private scalar is invalid",
    };
}

const begin_marker = "-----BEGIN PRIVATE KEY-----";
const end_marker = "-----END PRIVATE KEY-----";

const oid_ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 }; // 1.2.840.10045.2.1
const oid_prime256v1 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 }; // 1.2.840.10045.3.1.7

/// The caller should zero `pem` after use; every copy made here is zeroed before returning.
pub fn parsePem(pem: []const u8) Error!Ecdsa.SecretKey {
    const begin = std.mem.find(u8, pem, begin_marker) orelse return error.NotPem;
    const body_start = begin + begin_marker.len;
    const body_len = std.mem.find(u8, pem[body_start..], end_marker) orelse return error.NotPem;

    // A P-256 key is about 140 bytes; the room is there so that RSA keys get a precise error.
    var der: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &der);
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const der_len = decoder.decode(&der, pem[body_start..][0..body_len]) catch return error.NotPem;
    return parseDer(der[0..der_len]) catch |err| switch (err) {
        error.EndOfStream, error.UnexpectedElement, error.InvalidEncoding => error.NotPkcs8,
        else => |e| e,
    };
}

fn parseDer(der: []const u8) !Ecdsa.SecretKey {
    // PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm AlgorithmIdentifier, privateKey OCTET STRING, ... }
    var outer: asn1.der.Decoder = .{ .bytes = der };
    _ = try outer.sequence();
    if (!std.mem.eql(u8, outer.view(try outer.element(.primitive(.integer))), &.{0})) return error.NotPkcs8;

    // AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters (the named curve for EC keys) }
    const algorithm = try outer.sequence();
    if (!std.mem.eql(u8, outer.view(try outer.element(.primitive(.oid))), &oid_ec_public_key)) return error.NotEcKey;
    if (outer.index >= algorithm.slice.end) return error.NotPkcs8;
    if (!std.mem.eql(u8, outer.view(try outer.element(.primitive(.oid))), &oid_prime256v1)) return error.NotP256;
    outer.index = algorithm.slice.end;

    // ECPrivateKey ::= SEQUENCE { version INTEGER (1), privateKey OCTET STRING,
    //                             parameters [0] OID OPTIONAL, publicKey [1] BIT STRING OPTIONAL }
    var inner: asn1.der.Decoder = .{ .bytes = outer.view(try outer.element(.primitive(.octetstring))) };
    const ec_private_key = try inner.sequence();
    if (!std.mem.eql(u8, inner.view(try inner.element(.primitive(.integer))), &.{1})) return error.NotPkcs8;
    const scalar = inner.view(try inner.element(.primitive(.octetstring)));
    if (scalar.len != Ecdsa.SecretKey.encoded_length) return error.NotPkcs8;

    if (inner.index < ec_private_key.slice.end) {
        const next = try asn1.Element.decode(inner.bytes, inner.index);
        if (next.tag.class == .context_specific and @backingInt(next.tag.number) == 0) {
            var parameters: asn1.der.Decoder = .{ .bytes = next.slice.view(inner.bytes) };
            if (!std.mem.eql(u8, parameters.view(try parameters.element(.primitive(.oid))), &oid_prime256v1)) return error.NotP256;
        }
    }

    return Ecdsa.SecretKey.fromBytes(scalar[0..Ecdsa.SecretKey.encoded_length].*) catch error.InvalidScalar;
}

const testing = std.testing;

fn publicKeyFromSpki(spki_der: []const u8) ![65]u8 {
    return spki_der[spki_der.len - 65 ..][0..65].*;
}

test "parses an openssl-generated P-256 key to the same key pair openssl derives" {
    const secret = try parsePem(@embedFile("testkey-p256.p8"));
    const key_pair = try Ecdsa.KeyPair.fromSecretKey(secret);
    try testing.expectEqualSlices(
        u8,
        &try publicKeyFromSpki(@embedFile("testkey-p256.pub.der")),
        &key_pair.public_key.toUncompressedSec1(),
    );
}

/// Wraps a SEC1 ECPrivateKey in PKCS#8 + PEM, the way Apple's `.p8` files are laid out:
/// unlike openssl's PKCS#8 output, Apple's inner key keeps the optional [0] parameters.
fn appleShapedPem(buf: []u8, sec1: []const u8) ![]const u8 {
    var der: std.Io.Writer = .fixed(buf[0..512]);
    const algorithm = [_]u8{ 0x30, 0x13, 0x06, 0x07 } ++ oid_ec_public_key ++ [_]u8{ 0x06, 0x08 } ++ oid_prime256v1;
    const body_len = 3 + algorithm.len + 2 + sec1.len;
    try der.writeAll(&.{ 0x30, 0x81, @intCast(body_len), 0x02, 0x01, 0x00 });
    try der.writeAll(&algorithm);
    try der.writeAll(&.{ 0x04, @intCast(sec1.len) });
    try der.writeAll(sec1);

    var pem: std.Io.Writer = .fixed(buf[512..]);
    try pem.writeAll(begin_marker ++ "\n");
    try std.base64.standard.Encoder.encodeWriter(&pem, der.buffered());
    try pem.writeAll("\n" ++ end_marker ++ "\n");
    return pem.buffered();
}

test "accepts the optional [0] parameters that Apple's keys carry" {
    const sec1 = @embedFile("testkey-p256.sec1.der");
    try testing.expectEqual(@as(u8, 0xa0), sec1[2 + 3 + 2 + 32]); // the fixture really has [0]
    var buf: [1024]u8 = undefined;
    const secret = try parsePem(try appleShapedPem(&buf, sec1));
    const key_pair = try Ecdsa.KeyPair.fromSecretKey(secret);
    try testing.expectEqualSlices(
        u8,
        &try publicKeyFromSpki(@embedFile("testkey-p256.pub.der")),
        &key_pair.public_key.toUncompressedSec1(),
    );
}

test "rejects keys that are not PKCS#8 P-256, naming the cause" {
    try testing.expectError(error.NotP256, parsePem(@embedFile("testkey-p384.p8")));
    try testing.expectError(error.NotEcKey, parsePem(@embedFile("testkey-ed25519.p8")));
    try testing.expectError(error.NotPem, parsePem(""));
    try testing.expectError(error.NotPem, parsePem("hello\n"));
    try testing.expectError(error.NotPem, parsePem("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n"));
    try testing.expectError(error.NotPem, parsePem(begin_marker ++ "\n%%%%\n" ++ end_marker));
    try testing.expectError(error.NotPkcs8, parsePem(begin_marker ++ "\nMAMCAQA=\n" ++ end_marker));
}
