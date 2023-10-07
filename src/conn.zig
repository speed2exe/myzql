const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const protocol = @import("./protocol.zig");
const HandshakeV10 = protocol.handshake_v10.HandshakeV10;
const HandshakeResponse41 = protocol.handshake_response.HandshakeResponse41;
const Packet = protocol.packet.Packet;
const stream_buffered = @import("./stream_buffered.zig");

const max_packet_size = 1 << 24 - 1;

// TODO: make this adjustable during compile time
const buffer_size: usize = 4096;

pub const Conn = struct {
    const State = union(enum) {
        disconnected,
        connected,
    };
    state: State = .disconnected,
    stream: std.net.Stream = undefined,
    reader: stream_buffered.Reader = undefined,
    writer: stream_buffered.Writer = undefined,

    pub fn close(conn: *Conn) void {
        switch (conn.state) {
            .connected => {
                conn.stream.close();
                conn.state = .disconnected;
            },
            .disconnected => {},
        }
    }

    fn dial(conn: *Conn, address: std.net.Address) !void {
        const stream = try std.net.tcpConnectToAddress(address);
        conn.reader = stream_buffered.reader(stream);
        conn.writer = stream_buffered.writer(stream);
        conn.state = .connected;
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html
    pub fn connect(conn: *Conn, allocator: std.mem.Allocator, config: Config) !void {
        try conn.dial(config.address);

        const packet = try Packet.initFromReader(allocator, &conn.reader);
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
        const ack_packet = try Packet.initFromReader(allocator, &conn.reader);
        defer ack_packet.deinit(allocator);

        const realized_packet2 = ack_packet.realize(constants.MAX_CAPABILITIES, false);
        switch (realized_packet2) {
            .ok_packet => {},
            .error_packet => |x| {
                x.print();
                return error.DidNotReceiveOkPacket;
            },
            else => |x| {
                std.log.err("\nUnexpected packet: {any}\n", .{x});
                return error.DidNotReceiveOkPacket;
            },
        }
    }

    fn sendHandshakeResponse41(conn: Conn, handshake_v10: HandshakeV10, config: Config) !void {
        // debugging
        // try std.io.getStdErr().writer().print("v10: {any}\n", .{handshake_v10});
        // const auth_plugin_name = incoming.auth_plugin_name orelse return error.AuthPluginNameMissing;
        // try std.io.getStdErr().writer().print("auth_plugin_name: |{s}|\n", .{auth_plugin_name});
        // const auth_plugin_data = incoming.auth_plugin_data_part_1;
        // try std.io.getStdErr().writer().print("auth_plugin_data: |{s}|{d}||{d}|\n", .{ auth_plugin_data, auth_plugin_data.len, auth_plugin_data.* });
        // const auth_plugin_data_2 = incoming.auth_plugin_data_part_2;
        // try std.io.getStdErr().writer().print("auth_plugin_data_2: |{s}|{d}|{d}|\n", .{ auth_plugin_data_2, auth_plugin_data_2.len, auth_plugin_data_2 });
        //
        const password_resp = try auth_data_resp(
            handshake_v10.get_auth_plugin_name(),
            handshake_v10.get_auth_data(),
            config.password,
        );
        var resp_cap_flag = config.generate_capabilities_flags(handshake_v10.capability_flags());
        if (password_resp.len > 250) {
            resp_cap_flag |= constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA;
        }
        const response: HandshakeResponse41 = .{
            .database = config.database,
            .client_flag = resp_cap_flag,
            .character_set = config.collation,
            .username = config.username,
            .auth_response = password_resp,
        };
        var writer = conn.writer;
        try response.write_as_packet(&writer);
        try writer.flush();
    }

    pub fn ping(conn: Conn) !void {
        _ = conn;
        @panic("not implemented");
    }
};

inline fn auth_data_resp(auth_plugin_name: []const u8, auth_data: []const u8, password: []const u8) ![]const u8 {
    if (std.mem.eql(u8, auth_plugin_name, "caching_sha2_password")) {
        return &scrambleSHA256Password(auth_data, password);
    } else {
        // TODO: support more
        std.log.err("Unsupported auth plugin: {s}(contribution are welcome!)\n", .{auth_plugin_name});
        return error.UnsupportedAuthPlugin;
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
    try conn.connect(std.testing.allocator, default_config);
    // try conn.dial(default_config.address);
    // const packet = try conn.readPacket(std.testing.allocator);
    // defer packet.deinit();
    // const handshake = protocol.HandshakeV10.initFromPacket(packet);
    // try std.io.getStdOut().writeAll("hello!!!");
    // try protocol.HandshakeV10.dump(handshake, std.io.getStdOut().writer());
}
