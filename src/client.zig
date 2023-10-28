const std = @import("std");
const Config = @import("./config.zig").Config;
const Conn = @import("./conn.zig").Conn;
const QueryResult = @import("./conn.zig").QueryResult;

pub const Client = struct {
    config: Config,
    conn: Conn,

    pub fn init(config: Config) Client {
        return .{
            .config = config,
            .conn = .{},
        };
    }

    pub fn deinit(client: *Client) void {
        client.conn.close();
    }

    pub fn ping(client: *Client, allocator: std.mem.Allocator) !void {
        try client.connectIfNotConnected(allocator);
        try client.conn.ping(allocator, &client.config);
    }

    pub fn query(client: *Client, allocator: std.mem.Allocator, query_string: []const u8) !QueryResult {
        try client.connectIfNotConnected(allocator);
        return try client.conn.query(allocator, query_string);
    }

    fn connectIfNotConnected(c: *Client, allocator: std.mem.Allocator) !void {
        switch (c.conn.state) {
            .connected => {},
            .disconnected => {
                try c.conn.connect(allocator, &c.config);
            },
        }
    }
};
