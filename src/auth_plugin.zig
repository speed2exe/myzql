const std = @import("std");
const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

pub const AuthPlugin = enum {
    unspecified,
    mysql_native_password,
    sha256_password,
    caching_sha2_password,
    mysql_clear_password,
    unknown,

    pub fn fromName(name: []const u8) AuthPlugin {
        if (std.mem.eql(u8, name, "mysql_native_password")) {
            return .mysql_native_password;
        } else if (std.mem.eql(u8, name, "sha256_password")) {
            return .sha256_password;
        } else if (std.mem.eql(u8, name, "caching_sha2_password")) {
            return .caching_sha2_password;
        } else if (std.mem.eql(u8, name, "mysql_clear_password")) {
            return .mysql_clear_password;
        } else {
            return .unknown;
        }
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_caching_sha2_authentication_exchanges.html
// https://mariadb.com/kb/en/caching_sha2_password-authentication-plugin/
pub const caching_sha2_password_public_key_response = 0x01;
pub const caching_sha2_password_public_key_request = 0x02;
pub const caching_sha2_password_fast_auth_success = 0x03;
pub const caching_sha2_password_full_authentication_start = 0x04;

pub const DecodedPublicKey = struct {
    allocated: []const u8,
    value: struct {
        modulus: []const u8,
        exponent: []const u8,
    },

    pub fn deinit(d: *const DecodedPublicKey, allocator: std.mem.Allocator) void {
        allocator.free(d.allocated);
    }
};

pub fn decode_public_key(encoded_bytes: []const u8, allocator: std.mem.Allocator) !DecodedPublicKey {
    var decoded_pk: DecodedPublicKey = undefined;

    const start_marker = "-----BEGIN PUBLIC KEY-----";
    const end_marker = "-----END PUBLIC KEY-----";

    const base64_encoded = blk: {
        const start_marker_pos = std.mem.indexOfPos(u8, encoded_bytes, 0, start_marker).?;
        const base64_start = start_marker_pos + start_marker.len;
        const base64_end = std.mem.indexOfPos(u8, encoded_bytes, base64_start, end_marker).?;
        break :blk std.mem.trim(u8, encoded_bytes[base64_start..base64_end], " \t\r\n");
    };

    var dest = try allocator.alloc(u8, try base64.calcSizeUpperBound(base64_encoded.len));
    decoded_pk.allocated = dest;
    errdefer allocator.free(decoded_pk.allocated);

    const base64_decoded = blk: {
        const n = try base64.decode(dest, base64_encoded);
        break :blk decoded_pk.allocated[0..n];
    };

    // Example of DER-encoded public key:
    // SEQUENCE (2 elem)
    //   SEQUENCE (2 elem)
    //     OBJECT IDENTIFIER 1.2.840.113549.1.1.1 rsaEncryption (PKCS #1)
    //     NULL
    //   BIT STRING (2160 bit) 001100001000001000000001000010100000001010000010000000010000000100000…
    //     SEQUENCE (2 elem)
    //       INTEGER (2048 bit) 273994660083475464992607454720526089815923926694328893650906911229409…
    //       INTEGER 65537

    const bitstring = blk: {
        const Element = std.crypto.Certificate.der.Element;
        const top_level = try Element.parse(base64_decoded, 0);
        const seq_1 = try Element.parse(base64_decoded, top_level.slice.start);
        const bitstring_elem = try Element.parse(base64_decoded, seq_1.slice.end);
        break :blk std.mem.trim(u8, base64_decoded[bitstring_elem.slice.start..bitstring_elem.slice.end], &.{0});
    };

    const pk_decoded = try std.crypto.Certificate.rsa.PublicKey.parseDer(bitstring);
    decoded_pk.value = .{ .modulus = pk_decoded.modulus, .exponent = pk_decoded.exponent };
    return decoded_pk;
}

test "decode public key" {
    const pk =
        \\-----BEGIN PUBLIC KEY-----
        \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2QurErkXa1sGRr1AV4wJ
        \\m7cT0aSDrLsA+PHT8D6yjWhLEOocBzxuK0Z/1ytBAjRH9LtCbyHML81OIIACt03u
        \\Y+8xbtFLyOP0NxsLe5FzQ+R4PPQDnubtJeSa4E7jZZEIkAWS11cPo7/wXX3elfeb
        \\tzJDEjvFa7VDTcD1jh+0p03k+iPbt9f91+PauD/oCr0RbgL737/UTeN7F5sXCS9F
        \\OOPW+bqgdPV08c4Dx4qSxg9WrktRUA9RDxWdetzYyNVc9/+VsKbnCUFQuGCevvWi
        \\MHxq6dOI8fy+OYkaNo3UbU+4surE+JVIEdvAkhwVDN3DBBZ6gtpU5PukS4mcpUPt
        \\wQIDAQAB
        \\-----END PUBLIC KEY-----
    ;

    const d = try decode_public_key(pk, std.testing.allocator);
    defer d.deinit(std.testing.allocator);
}
