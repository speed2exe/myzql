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

    pub fn ping(client: Client) !void {
        try client.connectIfNotConnected();
        try client.conn.ping();
    }

    pub fn query(_: Client) void {
        std.debug.print("query\n");
    }

    fn connectIfNotConnected(c: Client) !void {
        switch (c.conn.state) {
            .connected => {},
            .disconnected => {
                try c.conn.connect(c.config.address);
            },
        }
    }
};

test Client {
    const c = Client.init(.{});
    try c.ping();
}
