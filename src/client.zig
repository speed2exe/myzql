const std = @import("std");
const conn = @import("./conn.zig");
const Config = @import("./config.zig").Config;
const protocol = @import("./protocol.zig");
const PrepareOk = protocol.prepared_statements.PrepareOk;
const Conn = conn.Conn;
const result = @import("./result.zig");
const QueryResult = result.QueryResult;
const PrepareResult = result.PrepareResult;
const TextResultRow = result.TextResultRow;
const BinaryResultRow = result.BinaryResultRow;

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

    pub fn query(client: *Client, allocator: std.mem.Allocator, query_string: []const u8) !QueryResult(TextResultRow) {
        try client.connectIfNotConnected(allocator);
        return client.conn.query(allocator, query_string);
    }

    pub fn prepare(client: *Client, allocator: std.mem.Allocator, query_string: []const u8) !PrepareResult {
        try client.connectIfNotConnected(allocator);
        return client.conn.prepare(allocator, query_string);
    }

    pub fn execute(client: *Client, allocator: std.mem.Allocator, prep_ok: *const PrepareOk) !QueryResult(BinaryResultRow) {
        try client.connectIfNotConnected(allocator);
        return client.conn.execute(allocator, prep_ok);
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
