const std = @import("std");
const FixedBytes = @import("./utils.zig").FixedBytes;
const PublicKey = std.crypto.Certificate.rsa.PublicKey;
const Sha1 = std.crypto.hash.Sha1;

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
    value: std.crypto.Certificate.rsa.PublicKey,

    pub fn deinit(d: *const DecodedPublicKey, allocator: std.mem.Allocator) void {
        allocator.free(d.allocated);
    }
};

pub fn decodePublicKey(encoded_bytes: []const u8, allocator: std.mem.Allocator) !DecodedPublicKey {
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
    decoded_pk.value = try std.crypto.Certificate.rsa.PublicKey.fromBytes(pk_decoded.exponent, pk_decoded.modulus);
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

    const d = try decodePublicKey(pk, std.testing.allocator);
    defer d.deinit(std.testing.allocator);
}

pub fn generate_auth_response(auth_plugin: AuthPlugin, auth_data: []const u8, password: []const u8) !FixedBytes(32) {
    var result: FixedBytes(32) = .{};
    switch (auth_plugin) {
        .caching_sha2_password => if (password.len > 0) {
            result.set(&scrambleSHA256Password(auth_data, password));
        },
        .sha256_password => {
            // need RSA-OAEP encryption
            return error.PleaseSupportASAP;
        },
        else => {
            std.log.warn("Unsupported auth plugin: {any}\n", .{auth_plugin});
            return error.UnsupportedAuthPlugin;
        },
    }
    return result;
}

// XOR(SHA256(password), SHA256(SHA256(SHA256(password)), scramble))
fn scrambleSHA256Password(scramble: []const u8, password: []const u8) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;

    var message1 = blk: {
        var hasher = Sha256.init(.{});
        hasher.update(password);
        break :blk hasher.finalResult();
    };
    const message2 = blk: {
        var hasher = Sha256.init(.{});
        hasher.update(&message1);
        var temp = hasher.finalResult();

        hasher = Sha256.init(.{});
        hasher.update(&temp);
        hasher.update(scramble);
        hasher.final(&temp);
        break :blk temp;
    };
    for (&message1, message2) |*m1, m2| {
        m1.* ^= m2;
    }
    return message1;
}

test "scrambleSHA256Password" {
    const scramble = [_]u8{ 10, 47, 74, 111, 75, 73, 34, 48, 88, 76, 114, 74, 37, 13, 3, 80, 82, 2, 23, 21 };
    const tests = [_]struct {
        password: []const u8,
        expected: [32]u8,
    }{
        .{
            .password = "secret",
            .expected = .{ 244, 144, 231, 111, 102, 217, 216, 102, 101, 206, 84, 217, 140, 120, 208, 172, 254, 47, 176, 176, 139, 66, 61, 168, 7, 20, 72, 115, 211, 11, 49, 44 },
        },
        .{
            .password = "secret2",
            .expected = .{ 171, 195, 147, 74, 1, 44, 243, 66, 232, 118, 7, 28, 142, 226, 2, 222, 81, 120, 91, 67, 2, 88, 167, 160, 19, 139, 199, 156, 77, 128, 11, 198 },
        },
    };

    for (tests) |t| {
        const actual = scrambleSHA256Password(&scramble, t.password);
        // std.debug.print("actual: {x}", .{ std.fmt.fmtSliceHexLower(&actual) });
        try std.testing.expectEqual(t.expected, actual);
    }
}

// https://mariadb.com/kb/en/sha256_password-plugin/#rsa-encrypted-password
// RSA encrypted value of XOR(password, seed) using server public key (RSA_PKCS1_OAEP_PADDING).
pub fn encryptPassword(allocator: std.mem.Allocator, password: []const u8, auth_data: *const [20]u8, pk: *const PublicKey) ![]const u8 {
    var plain = blk: {
        var plain = try allocator.alloc(u8, password.len + 1);
        @memcpy(plain.ptr, password);
        plain[plain.len - 1] = 0;
        break :blk plain;
    };
    defer allocator.free(plain);

    for (plain, 0..) |*c, i| {
        c.* ^= auth_data[i % 20];
    }

    return rsaEncryptOAEP(allocator, plain, pk);
}

fn rsaEncryptOAEP(allocator: std.mem.Allocator, msg: []const u8, pk: *const PublicKey) ![]const u8 {
    const init_hash = Sha1.init(.{});

    const lHash = blk: {
        var hash = init_hash;
        hash.update(&.{});
        break :blk hash.finalResult();
    };
    const digest_len = lHash.len;

    const k = (pk.n.bits() + 7) / 8; //  modulus size in bytes

    var em = try allocator.alloc(u8, k);
    defer allocator.free(em);
    @memset(em, 0);
    var seed = em[1 .. 1 + digest_len];
    var db = em[1 + digest_len ..];

    @memcpy(db[0..lHash.len], &lHash);
    db[db.len - msg.len - 1] = 1;
    @memcpy(db[db.len - msg.len ..], msg);
    std.crypto.random.bytes(seed);

    mgf1XOR(db, &init_hash, seed);
    mgf1XOR(seed, &init_hash, db);

    return encryptMsg(allocator, em, pk);
}

fn encryptMsg(allocator: std.mem.Allocator, msg: []const u8, pk: *const PublicKey) ![]const u8 {
    // can remove this if it's publicly exposed in std.crypto.Certificate.rsa
    // for now, just copy it from std.crypto.ff
    const max_modulus_bits = 4096;
    const Modulus = std.crypto.ff.Modulus(max_modulus_bits);
    const Fe = Modulus.Fe;

    const m = try Fe.fromBytes(pk.*.n, msg, .big);
    const e = try pk.n.powPublic(m, pk.e);

    var res = try allocator.alloc(u8, msg.len);
    try e.toBytes(res, .big);
    return res;
}

// mgf1XOR XORs the bytes in out with a mask generated using the MGF1 function
// specified in PKCS #1 v2.1.
fn mgf1XOR(dest: []u8, init_hash: *const Sha1, seed: []const u8) void {
    var counter: [4]u8 = .{ 0, 0, 0, 0 };
    var digest: [Sha1.digest_length]u8 = undefined;

    var done: usize = 0;
    while (done < dest.len) : (incCounter(&counter)) {
        var hash = init_hash.*;
        hash.update(seed);
        hash.update(counter[0..4]);
        digest = hash.finalResult();

        for (&digest) |*d| {
            if (done >= dest.len) break;
            dest[done] ^= d.*;
            done += 1;
        }
    }
}

// incCounter increments a four byte, big-endian counter.
fn incCounter(c: *[4]u8) void {
    inline for (&.{ 3, 2, 1, 0 }) |i| {
        const res = @addWithOverflow(c[i], 1);
        c[i] = res[0];
        if (res[1] == 0) return; // no overflow, so we're done
    }
}
