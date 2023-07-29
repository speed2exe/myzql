const std = @import("std");

const Conn = struct {
    const buffer_size = 4096;
    const Buffer = std.io.BufferedReader(buffer_size, std.net.Stream);
    const State = union(enum) {
        Disconnected,
        Connected: struct {
            stream: std.net.Stream,
            buffer: Buffer,
        },
    };

    host: []const u8,
    port: u16,
    allocator: std.mem.Allocator,
    state: State = .Disconnected,
    sequence: u8 = 0, // TODO:

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) Conn {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
        };
    }

    pub fn deinit(conn: Conn, allocator: std.mem.Allocator) void {
        switch (conn.State) {
            .Connected => std.net.streamDeinit(conn.state.Connected, allocator),
            .Disconnected => {},
        }
    }

    pub fn ping(conn: Conn) !void {
        try conn.connectIfDisconnected(conn.host, conn.port);
    }

    fn reader(conn: Conn) ?Buffer.Reader {
        switch (conn.state) {
            .Connected => return conn.state.Connected.buffer.reader(),
            .Disconnected => return null,
        }
    }

    fn connectIfDisconnected(conn: Conn) !void {
        switch (conn.state) {
            .Connected => {},
            .Disconnected => try conn.connect(),
        }
    }

    fn connect(conn: Conn) !void {
        // dial
        var stream = try std.net.tcpConnectToHost(conn.allocator, conn.host, conn.port);
        errdefer std.net.streamDeinit(stream, conn.allocator);
        const buffer = std.io.bufferedReader(stream.reader());
        conn.state = .Connected{ .stream = stream, .buffer = buffer };
        std.io.Reader;

        // handshake
        // read header
        const header = try buffer.reader().readBytesNoEof(4);
        const length = header[0] | header[1] << 8 | header[2] << 16;
        _ = length;
        // TODO: resume here
    }
};
