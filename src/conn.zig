const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const protocol = @import("./protocol.zig");
const HandshakeV10 = protocol.handshake_v10.HandshakeV10;
const ErrorPacket = protocol.generic_response.ErrorPacket;
const OkPacket = protocol.generic_response.OkPacket;
const HandshakeResponse41 = protocol.handshake_response.HandshakeResponse41;
const AuthSwitchRequest = protocol.auth_switch_request.AuthSwitchRequest;
const packet_writer = protocol.packet_writer;
const Packet = protocol.packet.Packet;
const stream_buffered = @import("./stream_buffered.zig");
const FixedBytes = @import("./utils.zig").FixedBytes;

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
    server_capabilities: u32 = 0,
    current_sequence_id: u8 = 0,

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

    fn hasCapability(conn: *Conn, capability: u32) bool {
        return conn.server_capabilities & capability > 0;
    }

    fn updateSequenceId(conn: *Conn, packet: Packet) !void {
        if (packet.sequence_id != conn.current_sequence_id) {
            std.log.err(
                "Unexpected sequence id: Conn:{d} != Packet: {d}\n",
                .{ packet.sequence_id, conn.current_sequence_id },
            );
            return error.UnexpectedPacket;
        }
        conn.current_sequence_id += 1;
    }

    fn generateSequenceId(conn: *Conn) u8 {
        const id = conn.current_sequence_id;
        conn.current_sequence_id += 1;
        return id;
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html
    pub fn connect(conn: *Conn, allocator: std.mem.Allocator, config: *const Config) !void {
        try conn.dial(config.address);
        var auth_plugin_name: FixedBytes(32) = .{};
        {
            const packet = try Packet.initFromReader(allocator, &conn.reader);
            defer packet.deinit(allocator);
            try conn.updateSequenceId(packet);

            const handshake_v10 = switch (packet.payload[0]) {
                constants.HANDSHAKE_V10 => HandshakeV10.initFromPacket(&packet, config.capability_flags()),
                constants.ERR => {
                    ErrorPacket.initFromPacket(true, &packet, 0).print();
                    return error.UnexpectedPacket;
                },
                else => {
                    std.log.err("Unexpected packet: {any}\n", .{packet});
                    return error.UnexpectedPacket;
                },
            };
            conn.server_capabilities = handshake_v10.capability_flags();
            if (handshake_v10.auth_plugin_name) |p| {
                try auth_plugin_name.set(p);
            }

            // TODO: TLS handshake if enabled

            // send handshake response to server
            if (conn.hasCapability(constants.CLIENT_PROTOCOL_41)) {
                try conn.sendHandshakeResponse41(handshake_v10, config);
            } else {
                // TODO: handle older protocol
                @panic("not implemented");
            }
        }

        while (true) {
            const packet = try Packet.initFromReader(allocator, &conn.reader);
            defer packet.deinit(allocator);
            try conn.updateSequenceId(packet);

            switch (packet.payload[0]) {
                constants.OK => {
                    std.debug.print("OK\n", .{});
                    _ = OkPacket.initFromPacket(&packet, config.capability_flags());
                    return;
                },
                constants.AUTH_SWITCH => {
                    const auth_switch = AuthSwitchRequest.initFromPacket(&packet);
                    try auth_plugin_name.set(auth_switch.plugin_name);
                    try conn.sendAuthSwitchResponse(
                        auth_switch.plugin_name,
                        auth_switch.plugin_name,
                        config,
                    );
                },
                constants.AUTH_MORE_DATA => {
                    const more_data = packet.payload[1..];
                    try conn.sendAuthSwitchResponse(
                        auth_plugin_name.get(),
                        more_data,
                        config,
                    );
                },
                constants.ERR => {
                    ErrorPacket.initFromPacket(false, &packet, 0).print();
                    return error.UnexpectedPacket;
                },
                else => {
                    std.log.err("Unexpected packet: {any}\n", .{packet});
                    return error.UnexpectedPacket;
                },
            }
        }

        // Server ack
    }

    fn sendAuthSwitchResponse(
        conn: *Conn,
        plugin_name: []const u8,
        plugin_data: []const u8,
        config: *const Config,
    ) !void {
        var auth_response: FixedBytes(32) = .{};
        try generate_auth_response(
            plugin_name,
            plugin_data,
            config.password,
            &auth_response,
        );
        var writer = conn.writer;
        try packet_writer.writeUInt24(&writer, @truncate(auth_response.len));
        try packet_writer.writeUInt8(&writer, conn.generateSequenceId());
        try writer.write(auth_response.get());
        try writer.flush();
    }

    fn sendHandshakeResponse41(conn: *Conn, handshake_v10: HandshakeV10, config: *const Config) !void {
        var auth_response: FixedBytes(32) = .{};
        try generate_auth_response(
            handshake_v10.get_auth_plugin_name(),
            &handshake_v10.get_auth_data(),
            config.password,
            &auth_response,
        );
        var resp_cap_flag = config.capability_flags();
        // TODO: support CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA
        // if (password_resp.len > 250) {
        //     resp_cap_flag |= constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA;
        // }
        const response: HandshakeResponse41 = .{
            .database = config.database,
            .client_flag = resp_cap_flag,
            .character_set = config.collation,
            .username = config.username,
            .auth_response = auth_response.get(),
        };
        var writer = conn.writer;
        try response.write_as_packet(&writer, conn.generateSequenceId());
        try writer.flush();
    }

    pub fn ping(conn: Conn) !void {
        _ = conn;
        @panic("not implemented");
    }
};

fn generate_auth_response(
    auth_plugin_name: []const u8,
    auth_data: []const u8,
    password: []const u8,
    out: *FixedBytes(32),
) !void {
    if (std.mem.eql(u8, auth_plugin_name, constants.caching_sha2_password)) {
        if (password.len == 0) {
            try out.set("");
        } else {
            try out.set(&scrambleSHA256Password(auth_data, password));
        }
    } else {
        // TODO: support more
        std.log.err("Unsupported auth plugin: |{s}|(contribution are welcome!)\n", .{auth_plugin_name});
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
        // std.debug.print("actual: {x}", .{ std.fmt.fmtSliceHexLower(&actual) });
        try std.testing.expectEqual(t.expected, actual);
    }
}

const default_config: Config = .{};

test "plain handshake" {
    var conn: Conn = .{};
    try conn.connect(std.testing.allocator, &default_config);
    // try conn.dial(default_config.address);
    // const packet = try conn.readPacket(std.testing.allocator);
    // defer packet.deinit();
    // const handshake = protocol.HandshakeV10.initFromPacket(packet);
    // try std.io.getStdOut().writeAll("hello!!!");
    // try protocol.HandshakeV10.dump(handshake, std.io.getStdOut().writer());
}
