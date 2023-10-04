const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const protocol = @import("./protocol.zig");
const Packet = protocol.packet.Packet;

const max_packet_size = 1 << 24 - 1;

// TODO: make this adjustable during compile time
const buffer_size: usize = 4096;

pub const Conn = struct {
    const StreamBufferedReader = std.io.BufferedReader(
        buffer_size,
        std.io.Reader(
            std.net.Stream,
            std.net.Stream.ReadError,
            std.net.Stream.read,
        ),
    );
    const Connected = struct {
        stream: std.net.Stream,
        buffered_reader: StreamBufferedReader,
    };
    const State = union(enum) {
        disconnected,
        connected: Connected,
    };

    state: State = .disconnected,

    pub fn close(conn: *Conn) void {
        switch (conn.state) {
            .connected => {
                conn.state.connected.stream.close();
                conn.state = .disconnected;
            },
            .disconnected => {},
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html
    pub fn connect(conn: *Conn, allocator: std.mem.Allocator, address: std.net.Address) !void {
        const stream = try std.net.tcpConnectToAddress(address);
        const buffered_reader = std.io.bufferedReaderSize(buffer_size, stream.reader());
        conn.state = .{ .connected = .{
            .stream = stream,
            .buffered_reader = buffered_reader,
        } };

        const packet = try conn.readPacket(allocator);
        defer packet.deinit(allocator);

        const realized_packet = packet.realize(constants.MAX_CAPABILITIES, true);
        const handshake_v10 = switch (realized_packet) {
            .handshake_v10 => realized_packet.handshake_v10,
            else => |x| {
                std.log.err("Unexpected packet: {any}\n", .{x});
                return error.UnexpectedPacket;
            },
        };

        try std.io.getStdErr().writer().print("v10: {any}", .{handshake_v10});
        // TODO: continue
    }

    pub fn ping(conn: Conn) !void {
        _ = conn;
    }

    fn auth(conn: Conn, auth_data: []u8, auth_plugin: []const u8) ![32]u8 {
        if (std.mem.eql(u8, auth_plugin, "caching_sha2_password")) {
            return scrambleSHA256Password(auth_data, conn.config.password);
        } else if (std.mem.eql(u8, auth_plugin, "mysql_old_password")) {
            if (!conn.config.allow_old_password) {
                std.log.err("MySQL server requested old password authentication, but it is disabled, you can enable in config");
                return error.OldPasswordDisabled;
            }
        }
    }

    fn auth_send(conn: Conn, auth_data: []const u8) !void {
        const pkt_len = 4 + auth_data.len;
        const data = try conn.writePacket(pkt_len);
        data[0] = pkt_len & 0xFF;
        data[1] = pkt_len >> 8 & 0xFF;
        data[2] = pkt_len >> 16 & 0xFF;
        data[3] = conn.sequence;
        conn.sequence += 1;
        @memcpy(data[4..], auth_data);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_v10.html
    fn readProtocolHandShakeV10() void {}

    fn streamBufferedReader(conn: Conn) !StreamBufferedReader {
        switch (conn.state) {
            .connected => return conn.state.connected.buffered_reader,
            .disconnected => return error.Disconnected,
        }
    }

    fn readPacket(conn: Conn, allocator: std.mem.Allocator) !Packet {
        var sbr = try conn.streamBufferedReader();
        return Packet.initFromReader(allocator, sbr.reader());
    }
};

// XOR(SHA256(password), SHA256(SHA256(SHA256(password)), scramble))
fn scrambleSHA256Password(scramble: []const u8, password: []const u8) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;

    var message1 = blk: {
        var hasher = Sha256.init(.{});
        hasher.update(password);
        break :blk hasher.finalResult();
    };
    const message2 = blk: {
        var hasher = Sha256.init(.{});
        hasher.update(&message1);
        var temp = hasher.finalResult();

        hasher = Sha256.init(.{});
        hasher.update(&temp);
        hasher.update(scramble);
        hasher.final(&temp);
        break :blk temp;
    };
    for (&message1, message2) |*m1, m2| {
        m1.* ^= m2;
    }
    return message1;
}

test "scrambleSHA256Password" {
    const scramble = [_]u8{ 10, 47, 74, 111, 75, 73, 34, 48, 88, 76, 114, 74, 37, 13, 3, 80, 82, 2, 23, 21 };
    const tests = [_]struct {
        password: []const u8,
        expected: [32]u8,
    }{
        .{
            .password = "secret",
            .expected = .{ 244, 144, 231, 111, 102, 217, 216, 102, 101, 206, 84, 217, 140, 120, 208, 172, 254, 47, 176, 176, 139, 66, 61, 168, 7, 20, 72, 115, 211, 11, 49, 44 },
        },
        .{
            .password = "secret2",
            .expected = .{ 171, 195, 147, 74, 1, 44, 243, 66, 232, 118, 7, 28, 142, 226, 2, 222, 81, 120, 91, 67, 2, 88, 167, 160, 19, 139, 199, 156, 77, 128, 11, 198 },
        },
    };

    for (tests) |t| {
        const actual = scrambleSHA256Password(&scramble, t.password);
        try std.testing.expectEqual(t.expected, actual);
    }
}

const default_config: Config = .{};

test "plain handshake" {
    var conn: Conn = .{};
    try conn.connect(std.testing.allocator, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3306));
    // try conn.dial(default_config.address);
    // const packet = try conn.readPacket(std.testing.allocator);
    // defer packet.deinit();
    // const handshake = protocol.HandshakeV10.initFromPacket(packet);
    // try std.io.getStdOut().writeAll("hello!!!");
    // try protocol.HandshakeV10.dump(handshake, std.io.getStdOut().writer());
}
