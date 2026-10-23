//! Integration tests for TLS connections.
//!
//! A TLS capable MySQL server has to be provided by the caller, otherwise all
//! tests of this file are skipped:
//! - `-Dtls-ca-path=/path/to/ca.pem`: CA certificate of the TLS server that
//!   listens on 127.0.0.1:3306 and uses a certificate issued for `localhost`
//!   and `127.0.0.1`
//! - `-Dtls-wrong-host-port=3308`: TLS server whose certificate is issued for
//!   another host, used to test host name verification
//! - `-Dnotls-port=3307`: MySQL/MariaDB server without TLS support
const std = @import("std");
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;
const Pool = myzql.pool.Pool;
const Config = myzql.config.Config;
const ResultSet = myzql.result.ResultSet;
const TextResultRow = myzql.result.TextResultRow;
const TextElems = myzql.result.TextElems;
const BinaryResultRow = myzql.result.BinaryResultRow;
const PreparedStatement = myzql.result.PreparedStatement;
const build_options = @import("build_options");
const test_config = @import("./config.zig").test_config;
const test_config_unix = @import("./config.zig").test_config_unix;

const io = std.testing.io;
const allocator = std.testing.allocator;

/// Account created by the authentication tests: it needs TLS and uses
/// `caching_sha2_password`, whose full authentication sends the password.
const tls_user = "myzql_tls_user";

/// `Config` of a TLS connection to the default server that verifies the
/// certificate of the server against the CA certificate of the test server.
fn tlsConfig() Config {
    return .{
        .username = test_config.username,
        .password = test_config.password,
        .ssl = true,
        .ssl_ca = build_options.tls_ca_path,
    };
}

/// `Config` that connects to `port` on 127.0.0.1 over TLS.
fn tlsConfigOnPort(port: u16, ssl_verify: bool) Config {
    var buf: [32]u8 = undefined;
    const literal = std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port}) catch unreachable;
    return .{
        .username = test_config.username,
        .password = test_config.password,
        .ssl = true,
        .ssl_verify = ssl_verify,
        .address = .{ .ip = std.Io.net.IpAddress.parseLiteral(literal) catch unreachable },
    };
}

/// Assert that the traffic of `c` is encrypted, i.e. that the connection was
/// upgraded to TLS, and that the server agrees by reporting a cipher for it.
fn expectEncrypted(c: *Conn) !void {
    try std.testing.expect(c.transport.isTls());

    const query_res = try c.query(io, "SHOW SESSION STATUS LIKE 'Ssl_cipher'");
    const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
    const row = (try rows.first(io)) orelse return error.MissingRow;
    const elems: TextElems = try row.textElems(allocator);
    defer elems.deinit(allocator);

    try std.testing.expectEqual(2, elems.elems.len);
    try std.testing.expectEqualStrings("Ssl_cipher", elems.elems[0] orelse "");
    const cipher = elems.elems[1] orelse return error.MissingValue;
    try std.testing.expect(cipher.len > 0);
}

/// Percent-encode every byte outside the unreserved set, so the CA path can be
/// embedded in a connection URL.
fn appendUrlEncoded(url: *std.ArrayList(u8), raw: []const u8) !void {
    for (raw) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try url.append(allocator, char),
        else => try url.print(allocator, "%{X:0>2}", .{char}),
    };
}

/// Create the account used by the authentication tests on the server `c` is
/// connected to. `REQUIRE SSL` makes the server reject unencrypted connections
/// to it, and re-identifying the account clears the `caching_sha2_password`
/// cache so the next connection has to perform a full authentication.
fn createTlsUser(c: *Conn) !void {
    var buf: [512]u8 = undefined;

    const create = try std.fmt.bufPrint(
        &buf,
        "CREATE USER IF NOT EXISTS '{s}'@'%' IDENTIFIED WITH caching_sha2_password BY '{s}' REQUIRE SSL",
        .{ tls_user, test_config.password },
    );
    const create_res = try c.query(io, create);
    _ = try create_res.expect(.ok);

    const grant = try std.fmt.bufPrint(&buf, "GRANT ALL ON *.* TO '{s}'@'%'", .{tls_user});
    const grant_res = try c.query(io, grant);
    _ = try grant_res.expect(.ok);

    const alter = try std.fmt.bufPrint(
        &buf,
        "ALTER USER '{s}'@'%' IDENTIFIED WITH caching_sha2_password BY '{s}'",
        .{ tls_user, test_config.password },
    );
    const alter_res = try c.query(io, alter);
    _ = try alter_res.expect(.ok);
}

test "tls - connect and query" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    var config = tlsConfig();
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);

    try expectEncrypted(&c);
    try c.ping(io);

    const query_res = try c.query(io, "SELECT 1, 'two', NULL");
    const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
    const row = (try rows.first(io)) orelse return error.MissingRow;
    const elems: TextElems = try row.textElems(allocator);
    defer elems.deinit(allocator);
    try std.testing.expectEqual(3, elems.elems.len);
    try std.testing.expectEqualStrings("1", elems.elems[0] orelse "");
    try std.testing.expectEqualStrings("two", elems.elems[1] orelse "");
    try std.testing.expect(elems.elems[2] == null);

    // the connection is still usable after the query
    try c.ping(io);
}

test "tls - connect with host name" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    // `localhost` is verified as a host name, which uses the subject
    // alternative names of the certificate instead of an IP literal
    var config = tlsConfig();
    config.address = .{ .host = .{
        .name = try std.Io.net.HostName.init("localhost"),
        .port = test_config.address.ip.getPort(),
    } };
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);

    try expectEncrypted(&c);
    try c.ping(io);
}

test "tls - large payload" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    var config = tlsConfig();
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);

    // a row of 200 KB spans several MySQL packets and therefore several TLS
    // records, which exercises reading and writing more than one buffer at a time
    const query_res = try c.query(io, "SELECT REPEAT('x', 200000), LENGTH(REPEAT('y', 100000))");
    const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
    const row = (try rows.first(io)) orelse return error.MissingRow;
    const elems: TextElems = try row.textElems(allocator);
    defer elems.deinit(allocator);

    const repeated = elems.elems[0] orelse return error.MissingValue;
    try std.testing.expectEqual(200000, repeated.len);
    try std.testing.expectEqualStrings("100000", elems.elems[1] orelse "");
    try c.ping(io);
}

test "tls - prepared statement" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    var config = tlsConfig();
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);

    const prep_res = try c.prepare(allocator, io, "SELECT ? + 1");
    defer prep_res.deinit(allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    const exec_res = try c.execute(io, &prep_stmt, .{41});
    const rows: ResultSet(BinaryResultRow) = try exec_res.expect(.rows);
    const row = (try rows.first(io)) orelse return error.MissingRow;
    const Dest = struct { value: u32 };
    var dest: Dest = undefined;
    try row.scan(&dest);
    try std.testing.expectEqual(42, dest.value);
}

test "tls - pool reuses encrypted connections" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    const config = tlsConfig();
    var pool = try Pool.init(allocator, &config, .{ .max_size = 2 });
    defer pool.deinit(io);

    { // first connection
        var mc = try pool.acquireManaged(io);
        defer mc.deinit(io);
        try expectEncrypted(mc.raw());
        try mc.ping(io);
    }
    { // the returned connection is reused and is still encrypted
        var mc = try pool.acquireManaged(io);
        defer mc.deinit(io);
        try expectEncrypted(mc.raw());
        try mc.ping(io);
    }
    try std.testing.expectEqual(1, pool.totalCount(io));
}

test "tls - connection url parameters" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    const port = test_config.address.ip.getPort();
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(allocator);

    try url.appendSlice(allocator, "mysql://");
    try appendUrlEncoded(&url, test_config.username);
    try url.append(allocator, ':');
    try appendUrlEncoded(&url, test_config.password);
    try url.print(allocator, "@127.0.0.1:{d}/?ssl=true&sslCa=", .{port});
    try appendUrlEncoded(&url, build_options.tls_ca_path.?);

    var url_config = try Config.fromUrl(allocator, url.items);
    defer url_config.deinit(allocator);
    try std.testing.expectEqual(true, url_config.value.ssl);
    try std.testing.expectEqual(true, url_config.value.ssl_verify);
    try std.testing.expectEqualStrings(build_options.tls_ca_path.?, url_config.value.ssl_ca.?);

    var c = try Conn.init(allocator, io, &url_config.value);
    defer c.deinit(allocator, io);
    try expectEncrypted(&c);
    try c.ping(io);
}

test "tls - server without tls support" {
    const port = build_options.notls_port orelse return error.SkipZigTest;

    // `ssl` only requests TLS, it does not silently fall back to an
    // unencrypted connection
    var config = tlsConfigOnPort(port, true);
    try std.testing.expectError(
        error.ServerDoesNotSupportTls,
        Conn.init(allocator, io, &config),
    );
}

test "tls - untrusted certificate is rejected" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    // the CA of the test server is not in the system trust store
    var config = tlsConfig();
    config.ssl_ca = null;
    try std.testing.expectError(
        error.TlsCertificateNotVerified,
        Conn.init(allocator, io, &config),
    );
}

test "tls - host name of the certificate is verified" {
    const port = build_options.tls_wrong_host_port orelse return error.SkipZigTest;
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    // the certificate is signed by the CA of the test, but issued for another host
    var config = tlsConfigOnPort(port, true);
    config.ssl_ca = build_options.tls_ca_path;
    try std.testing.expectError(
        error.CertificateHostMismatch,
        Conn.init(allocator, io, &config),
    );
}

test "tls - verification can be disabled" {
    const port = build_options.tls_wrong_host_port orelse return error.SkipZigTest;

    // the connection is encrypted, but the certificate of the server is
    // accepted without being validated
    var config = tlsConfigOnPort(port, false);
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);
    try expectEncrypted(&c);
    try c.ping(io);
}

test "tls - cleartext password authentication" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    var admin_config = tlsConfig();
    {
        var admin = try Conn.init(allocator, io, &admin_config);
        defer admin.deinit(allocator, io);
        try createTlsUser(&admin);
    }

    // over a secure channel `caching_sha2_password` sends the password in
    // cleartext instead of requesting the RSA public key of the server
    var config = tlsConfig();
    config.username = tls_user;
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);
    try expectEncrypted(&c);
    try c.ping(io);
}

test "tls - user that requires tls is rejected without it" {
    if (build_options.tls_ca_path == null) return error.SkipZigTest;

    var admin_config = tlsConfig();
    {
        var admin = try Conn.init(allocator, io, &admin_config);
        defer admin.deinit(allocator, io);
        try createTlsUser(&admin);
    }

    // the server rejects the account over an unencrypted connection
    var config = tlsConfig();
    config.username = tls_user;
    config.ssl = false;
    try std.testing.expectError(
        error.ErrorPacket,
        Conn.init(allocator, io, &config),
    );
}

test "tls - unix socket ignores ssl" {
    const unix_config = test_config_unix orelse return error.SkipZigTest;

    // a unix socket is already a local channel, so `ssl` is ignored instead of
    // failing the connection
    var config = unix_config;
    config.ssl = true;
    var c = try Conn.init(allocator, io, &config);
    defer c.deinit(allocator, io);
    try std.testing.expect(!c.transport.isTls());
    try c.ping(io);
}
