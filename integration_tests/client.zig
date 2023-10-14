const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;

test "ping" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    try c.ping();
}
