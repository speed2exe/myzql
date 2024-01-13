const myzql = @import("myzql");
const Conn = myzql.conn.Conn;
const std = @import("std");
const test_config = @import("./config.zig").test_config;

test "connect" {
    var conn: Conn = .{};
    try conn.connect(std.testing.allocator, &test_config);
    defer conn.close();
}
