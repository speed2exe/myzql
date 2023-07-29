const std = @import("std");
const mysql_const = @import("./mysql_const.zig");
const Config = @import("./config.zig").Config;

const maxPacketSize = 1 << 24 - 1;

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
    config: Config,
    state: State = .Disconnected,
    sequence: u8 = 0, // TODO: Not sure what this does, check
    clientFlags: u32 = 0, // TODO: Not sure what this does, check

    pub fn init(host: []const u8, port: u16, config: Config) Conn {
        return .{
            .host = host,
            .port = port,
            .config = config,
        };
    }

    pub fn close(conn: Conn) void {
        switch (conn.State) {
            .Connected => {
                conn.state.Connected.stream.close();
                conn.state = .Disconnected;
            },
            .Disconnected => {},
        }
    }

    pub fn ping(conn: Conn) !void {
        try conn.connectIfDisconnected(conn.host, conn.port);
    }

    fn connectIfDisconnected(conn: Conn) !void {
        switch (conn.state) {
            .Connected => {},
            .Disconnected => try conn.connect(),
        }
    }

    fn connect(conn: Conn, allocator: std.mem.Allocator) !void {
        // dial
        var stream = try std.net.tcpConnectToHost(conn.allocator, conn.host, conn.port);
        const buffer = std.io.bufferedReader(stream.reader());
        conn.state = .Connected{ .stream = stream, .buffer = buffer };
        errdefer conn.close();

        const packet = try conn.readPacket(allocator);
        defer conn.allocator.free(packet);

        if (packet[0] == mysql_const.i_err) {
            return conn.handleErrorPacket(packet);
        }
        if (packet[0] < mysql_const.min_protocol_version) {
            std.log.err("unsupported protocol version: {d}, expected at least {d}\n", packet[0], mysql_const.min_protocol_version);
            return error.UnsupportedProtocolVersion;
        }

        // Server version: Null-terminated string
        var pos = std.mem.indexOfScalarPos(u8, packet, 1, 0);
        const server_version = packet[1 .. pos - 1];
        std.log.info("server version: {s}\n", server_version);

        // Connection id: 4 bytes
        const connection_id = std.mem.readIntSliceLittle(u32, packet[pos .. pos + 4]);
        std.log.info("connection id: {d}\n", connection_id);
        pos += 4 + 1; // +1 for filler

        // Auth plugin data part 1: 8 bytes
        const auth_data = packet[pos .. pos + 8];
        pos += 8 + 1; // +1 for filler
        std.log.info("auth data: {x}\n", auth_data);

        // Capabilities: 2 bytes
        const capabilities = std.mem.readIntSliceLittle(u16, packet[pos .. pos + 2]);
        std.log.info("capabilities: {x}\n", capabilities);
        pos += 2;

        // TODO!
    }

    fn readPacket(conn: Conn, allocator: std.mem.Allocator) ![]u8 {
        errdefer conn.close();

        var accumulator = std.ArrayList(u8).init(allocator);
        errdefer accumulator.deinit();

        const reader = conn.state.Connected.buffer.reader();

        while (true) {
            const header = try reader.readBytesNoEof(4);
            const pkt_len = header[0] | header[1] << 8 | header[2] << 16;

            if (header[3] != conn.sequence) {
                if (header[3] > conn.sequence) {
                    std.log.err("commands out of sync. Did you run multiple statements at once?\n");
                    return error.PacketSyncMulti;
                }
                std.log.err("commands out of sync. You can't run this command now\n");
                return error.PacketSync;
            }
            conn.sequence += 1;

            if (pkt_len == 0) {
                if (accumulator.items.len == 0) {
                    return error.InvalidConnection;
                }
                return accumulator.toOwnedSlice();
            }

            var data = try accumulator.addManyAsSlice(pkt_len);
            try reader.readAll(data);
        }
    }

    fn handleErrorPacket(conn: Conn, packet: []const u8) !void {
        if (packet[0] != mysql_const.i_err) {
            std.log.err("expected error packet, got %x\n", packet[0]);
            return error.MalformedPacket;
        }

        const err_number = std.mem.readIntSliceLittle(u16, packet[1..3]);
        std.log.err("error number: %d\n", err_number);

        // 1792: ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION
        // 1290: ER_OPTION_PREVENTS_STATEMENT (returned by Aurora during failover)
        if ((err_number == 1792 or err_number == 1290) and conn.config.reject_read_only) {
            // Oops; we are connected to a read-only connection, and won't be able
            // to issue any write statements. Since RejectReadOnly is configured,
            // we throw away this connection hoping this one would have write
            // permission. This is specifically for a possible race condition
            // during failover (e.g. on AWS Aurora). See README.md for more.
            //
            // We explicitly close the connection before returning
            // driver.ErrBadConn to ensure that `database/sql` purges this
            // connection and initiates a new one for next statement next time.
            conn.close();
            std.log.err("rejecting read-only connection\n");
            return error.DriverBadConnection;
        }

        // SQL State [optional: # + 5bytes string]
        if (packet[3] == 0x23) {
            std.log.err("sql state: {d}\n", packet[4..9]);
            std.log.err("error message: {s}\n", packet[9..]);
        } else {
            std.log.err("error message: {s}\n", packet[3..]);
        }
    }
};
