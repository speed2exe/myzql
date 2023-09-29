const std = @import("std");
const myzql = @import("myzql");

pub const Client = struct {
    config: myzql.Config,
    conn: myzql.Conn,
    allocator: std.mem.Allocator,

    pub fn init(config: myzql.Config, allocator: std.mem.Allocator) Client {
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
        std.debug.print("query\n");
    }

    fn connectIfNotConnected(c: *Client) !void {
        switch (c.conn.state) {
            .connected => {},
            .disconnected => {
                try c.conn.connect(c.allocator, c.config.address);
            },
        }
    }
};

test "ping" {
    var c = Client.init(.{}, std.testing.allocator);
    try c.ping();
}
