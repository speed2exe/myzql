const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const protocol = @import("./protocol.zig");
const HandshakeV10 = protocol.handshake_v10.HandshakeV10;
const HandshakeResponse41 = protocol.handshake_response.HandshakeResponse41;
const Packet = protocol.packet.Packet;

const max_packet_size = 1 << 24 - 1;

// TODO: make this adjustable during compile time
const buffer_size: usize = 4096;

pub const Conn = struct {
    const StreamBufferedReader = std.io.BufferedReader(
        buffer_size, // should just use stream directly instead of wrapping with io.reader
        std.io.Reader(
            std.net.Stream,
            std.net.Stream.ReadError,
            std.net.Stream.read,
        ),
    );
    const StreamBufferedWriter = std.io.BufferedWriter(
        buffer_size,
        std.io.Writer(
            std.net.Stream,
            std.net.Stream.WriteError,
            std.net.Stream.write,
        ),
    );
    const Connected = struct {
        stream: std.net.Stream,
        buffered_reader: StreamBufferedReader,
        buffered_writer: StreamBufferedWriter,
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
    pub fn connect(conn: *Conn, allocator: std.mem.Allocator, config: Config) !void {
        const stream = try std.net.tcpConnectToAddress(config.address);
        const buffered_reader = std.io.bufferedReaderSize(buffer_size, stream.reader());
        const buffered_writer = std.io.bufferedWriter(stream.writer());
        conn.state = .{
            .connected = .{
                .stream = stream,
                .buffered_reader = buffered_reader,
                .buffered_writer = buffered_writer,
            },
        };

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

        // TODO: TLS handshake if enabled

        // send handshake response to server
        const server_capabilities = handshake_v10.capability_flags();
        if (server_capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            try conn.sendHandshakeResponse41(handshake_v10, config);
        } else {
            // TODO: handle older protocol
            @panic("not implemented");
        }

        // Server ack
        const packet2 = try conn.readPacket(allocator);
        defer packet2.deinit(allocator);

        const realized_packet2 = packet.realize(constants.MAX_CAPABILITIES, false);
        switch (realized_packet2) {
            .ok_packet => {},
            else => |x| {
                std.log.err("\nUnexpected packet: {any}\n", .{x});
                return error.DidNotReceiveOkPacket;
            },
        }
    }

    fn sendHandshakeResponse41(conn: Conn, handshake_v10: HandshakeV10, config: Config) !void {
        // debugging
        // try std.io.getStdErr().writer().print("v10: {any}\n", .{incoming});
        // const auth_plugin_name = incoming.auth_plugin_name orelse return error.AuthPluginNameMissing;
        // try std.io.getStdErr().writer().print("auth_plugin_name: |{s}|\n", .{auth_plugin_name});
        // const auth_plugin_data = incoming.auth_plugin_data_part_1;
        // try std.io.getStdErr().writer().print("auth_plugin_data: |{s}|{d}||{d}|\n", .{ auth_plugin_data, auth_plugin_data.len, auth_plugin_data.* });
        // const auth_plugin_data_2 = incoming.auth_plugin_data_part_2;
        // try std.io.getStdErr().writer().print("auth_plugin_data_2: |{s}|{d}|{d}|\n", .{ auth_plugin_data_2, auth_plugin_data_2.len, auth_plugin_data_2 });
        //
        const password_resp = auth_data_resp(
            handshake_v10.get_auth_plugin_name(),
            handshake_v10.get_auth_data(),
            config.password,
        );
        const resp_cap_flag = config.generate_capabilities_flag(handshake_v10.capability_flags());
        if (password_resp.len > 250) {
            resp_cap_flag |= constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA;
        }

        var writer = try conn.streamBufferedWriter();
        const response: HandshakeResponse41 = .{
            .client_flags = resp_cap_flag,
            .character_set = config.collation,
            .username = config.username,
            .auth_response = password_resp,
        };
        try response.write(&writer, 0);
        try writer.flush();
    }

    pub fn ping(conn: Conn) !void {
        _ = conn;
        @panic("not implemented");
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

    fn streamBufferedReader(conn: Conn) !StreamBufferedReader {
        switch (conn.state) {
            .connected => return conn.state.connected.buffered_reader,
            .disconnected => return error.Disconnected,
        }
    }

    fn streamBufferedWriter(conn: Conn) !StreamBufferedWriter {
        switch (conn.state) {
            .connected => return conn.state.connected.buffered_writer,
            .disconnected => return error.Disconnected,
        }
    }

    fn readPacket(conn: Conn, allocator: std.mem.Allocator) !Packet {
        var sbr = try conn.streamBufferedReader();
        return Packet.initFromReader(allocator, sbr.reader());
    }
};

inline fn auth_data_resp(auth_plugin_name: []const u8, auth_data: []const u8, password: []const u8) !void {
    if (std.mem.eql(u8, auth_plugin_name, "caching_sha2_password")) {
        scrambleSHA256Password(auth_data, password);
    } else {
        // TODO: support more
        std.log.err("Unsupported auth plugin: {s}(contribution are welcome!)\n", .{auth_plugin_name});
    }
}

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
