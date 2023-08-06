const std = @import("std");
const Config = @import("./config.zig").Config;
const Conn = @import("./conn.zig").Conn;

pub const Client = struct {
    config: Config,
    conn: Conn,

    pub fn init(config: Config) Client {
        return .{
            .config = config,
            .conn = Conn.init(config),
        };
    }

    pub fn ping(client: Client) void {
        _ = client;
        std.debug.print("ping\n");
    }

    pub fn query(_: Client) void {
        std.debug.print("query\n");
    }
};
