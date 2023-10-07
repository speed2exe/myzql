const std = @import("std");
const Config = @import("./config.zig").Config;
const Conn = @import("./conn.zig").Conn;

pub const Client = struct {
    config: Config,
    conn: Conn,
    allocator: std.mem.Allocator,

    pub fn init(config: Config, allocator: std.mem.Allocator) Client {
        return .{
            .config = config,
            .conn = .{},
            .allocator = allocator,
        };
    }

    pub fn ping(client: *Client) !void {
        try client.connectIfNotConnected();
        try client.conn.ping();
    }

    pub fn query(_: Client) void {
        std.debug.print("query\n", .{});
    }

    fn connectIfNotConnected(c: *Client) !void {
        switch (c.conn.state) {
            .connected => {},
            .disconnected => {
                try c.conn.connect(c.allocator, &c.config);
            },
        }
    }
};

test "ping" {
    // var c = Client.init(.{}, std.testing.allocator);
    // try c.ping();
}
