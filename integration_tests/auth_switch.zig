const std = @import("std");
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;
const Config = myzql.config.Config;
const test_config = @import("./config.zig").test_config;

const io = std.testing.io;
const allocator = std.testing.allocator;

// Reproducer for the AUTH_SWITCH_REQUEST bug:
//
// Server: mysql:8.0 with DEFAULT authentication plugin (caching_sha2_password).
// Account: created with mysql_native_password.
//
// On connect, the server responds to the client's caching_sha2_password
// scramble with an AuthSwitchRequest (payload 0xFE "mysql_native_password" 0x00 <salt>).
// myzql's auth handling treats 0xFE as EOF, so this fails with
// error.UnexpectedPacket / "Got packets out of order" (1156).
test "auth switch: caching_sha2_password server switches to mysql_native_password" {
    // 1. Connect as root (caching_sha2_password, no auth switch) to set up the account.
    {
        var c = try Conn.init(allocator, io, &test_config);
        defer c.deinit(allocator, io);

        // MySQL uses IDENTIFIED WITH ... BY, MariaDB uses IDENTIFIED VIA ... USING PASSWORD().
        // Try both; one of them will succeed depending on the server flavor.
        const setup_queries = [_][]const u8{
            "DROP USER IF EXISTS 'authswitch'@'%'",
            "CREATE USER 'authswitch'@'%' IDENTIFIED WITH mysql_native_password BY 'password'",
            "CREATE USER 'authswitch'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('password')",
        };
        for (setup_queries) |q| {
            const res = c.query(io, q) catch continue;
            _ = res.expect(.ok) catch continue;
        }
    }

    // 2. Connect as the mysql_native_password account. The server will send
    //    an AuthSwitchRequest because the client offered caching_sha2_password.
    const switch_config: Config = .{
        .username = "authswitch",
        .password = "password",
    };
    var c = try Conn.init(allocator, io, &switch_config);
    defer c.deinit(allocator, io);
    try c.ping(io);
}
