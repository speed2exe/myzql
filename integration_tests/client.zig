const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;

test "ping" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    try c.ping();
}

test "query database create and drop" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    _ = @field(try c.query("CREATE DATABASE testdb"), "ok");
    _ = @field(try c.query("DROP DATABASE testdb"), "ok");
}

test "query syntax error" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    _ = @field(try c.query("garbage query"), "err");
}

// test "query select 1" {
//     var c = Client.init(test_config, std.testing.allocator);
//     defer c.deinit();
//
//     const qr = try c.query("SELECT 1");
//     _ = qr;
// }
