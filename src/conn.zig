const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const auth_plugin = @import("./auth_plugin.zig");
const AuthPlugin = auth_plugin.AuthPlugin;
const protocol = @import("./protocol.zig");
const HandshakeV10 = protocol.handshake_v10.HandshakeV10;
const ErrorPacket = protocol.generic_response.ErrorPacket;
const OkPacket = protocol.generic_response.OkPacket;
const HandshakeResponse41 = protocol.handshake_response.HandshakeResponse41;
const AuthSwitchRequest = protocol.auth_switch_request.AuthSwitchRequest;
const QueryRequest = protocol.text_command.QueryRequest;
const prepared_statements = protocol.prepared_statements;
const PrepareRequest = prepared_statements.PrepareRequest;
const PrepareOk = prepared_statements.PrepareOk;
const ExecuteRequest = prepared_statements.ExecuteRequest;
const packet_writer = protocol.packet_writer;
const Packet = protocol.packet.Packet;
const stream_buffered = @import("./stream_buffered.zig");
const FixedBytes = @import("./utils.zig").FixedBytes;
const PacketReader = @import("./protocol/packet_reader.zig").PacketReader;
const ColumnDefinition41 = @import("./protocol/column_definition.zig").ColumnDefinition41;

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
    client_capabilities: u32 = 0,
    sequence_id: u8 = 0,

    // TODO: add options
    /// caller must consume the result by switching on the result's value
    pub fn query(conn: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !QueryResult {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        const query_request: QueryRequest = .{ .query = query_string };
        try conn.sendPacketUsingSmallPacketWriter(query_request);
        const response_packet = try conn.readPacket(allocator);
        return .{
            .packet = response_packet,
            .value = switch (response_packet.payload[0]) {
                constants.OK => .{ .ok = OkPacket.initFromPacket(&response_packet, conn.client_capabilities) },
                constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &response_packet, conn.client_capabilities) },
                constants.LOCAL_INFILE_REQUEST => _ = @panic("not implemented"),
                else => .{
                    .rows = blk: {
                        var packet_reader = PacketReader.initFromPacket(&response_packet);
                        const column_count = packet_reader.readLengthEncodedInteger();
                        var result_set = try TextResultSet.init(allocator, conn, column_count);
                        break :blk result_set;
                    },
                },
            },
        };
    }

    // TODO: add options
    pub fn prepare(conn: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !PrepareResult {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        const prepare_request: PrepareRequest = .{ .query = query_string };
        try conn.sendPacketUsingSmallPacketWriter(prepare_request);
        const response_packet = try conn.readPacket(allocator);
        return .{
            .packet = response_packet,
            .value = switch (response_packet.payload[0]) {
                constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &response_packet, conn.client_capabilities) },
                constants.OK => .{ .ok = PrepareOk.initFromPacket(&response_packet, conn.client_capabilities) },
                else => return response_packet.asError(conn.client_capabilities),
            },
        };
    }

    // TODO: add options
    pub fn execute(conn: *Conn, allocator: std.mem.Allocator, prep_ok: PrepareOk) !ExecuteResponse {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        const execute_request: ExecuteRequest = .{ .prep_ok = &prep_ok };
        try conn.sendPacketUsingSmallPacketWriter(execute_request);
        const response_packet = try conn.readPacket(allocator);
        return .{ .packet = response_packet, .conn = conn };
    }

    pub fn close(conn: *Conn) void {
        switch (conn.state) {
            .connected => {
                conn.stream.close();
                conn.state = .disconnected;
            },
            .disconnected => {},
        }
    }

    pub fn ping(conn: *Conn, allocator: std.mem.Allocator, config: *const Config) !void {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        try conn.sendBytesAsPacket(&[_]u8{constants.COM_PING});
        const packet = try conn.readPacket(allocator);
        defer packet.deinit(allocator);
        switch (packet.payload[0]) {
            constants.OK => _ = OkPacket.initFromPacket(&packet, config.capability_flags()),
            else => return packet.asError(config.capability_flags()),
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html
    pub fn connect(conn: *Conn, allocator: std.mem.Allocator, config: *const Config) !void {
        try conn.dial(config.address);
        errdefer conn.close();
        conn.sequence_id = 0;
        conn.client_capabilities = config.capability_flags();

        var auth: AuthPlugin = undefined;
        {
            const packet = try conn.readPacket(allocator);
            defer packet.deinit(allocator);

            const handshake_v10 = switch (packet.payload[0]) {
                constants.HANDSHAKE_V10 => HandshakeV10.initFromPacket(&packet, conn.client_capabilities),
                else => return packet.asError(conn.client_capabilities),
            };
            conn.server_capabilities = handshake_v10.capability_flags();
            auth = handshake_v10.get_auth_plugin();

            // TODO: TLS handshake if enabled

            // send handshake response to server
            if (conn.hasCapability(constants.CLIENT_PROTOCOL_41)) {
                try conn.sendHandshakeResponse41(
                    auth,
                    &handshake_v10.get_auth_data(),
                    config,
                );
            } else {
                // TODO: handle older protocol
                @panic("not implemented");
            }
        }

        while (true) {
            const packet = try conn.readPacket(allocator);
            defer packet.deinit(allocator);

            switch (packet.payload[0]) {
                constants.OK => {
                    _ = OkPacket.initFromPacket(&packet, conn.client_capabilities);
                    return;
                },
                constants.AUTH_SWITCH => {
                    const auth_switch = AuthSwitchRequest.initFromPacket(&packet);
                    auth = AuthPlugin.fromName(auth_switch.plugin_name);
                    try conn.sendAuthSwitchResponse(
                        auth,
                        auth_switch.plugin_data,
                        config,
                    );
                },
                constants.AUTH_MORE_DATA => {
                    // more auth exchange based on auth_method
                    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_authentication_methods.html
                    const more_data = packet.payload[1..];
                    switch (auth) {
                        .caching_sha2_password => {
                            switch (more_data[0]) {
                                auth_plugin.caching_sha2_password_fast_auth_success => {
                                    // Fast auth success
                                },
                                auth_plugin.caching_sha2_password_full_authentication_start => {
                                    // Full Authentication start

                                    // TODO: Implement sending encrypted password with server's public key
                                    // when we can parse, decrypt and ecrypt data with RSA
                                    //
                                    // try conn.sendAndFlushAsPacket(&[_]u8{auth_plugin.caching_sha2_password_public_key_request});
                                    // const public_key_packet = try conn.readPacket(allocator);
                                    // defer public_key_packet.deinit(allocator);

                                    // if TLS, send password as plain text
                                    // try conn.sendAndFlushAsPacket(config.password);
                                    return error.NotImplemented;
                                },
                                else => return error.UnsupportedCachingSha2PasswordMoreData,
                            }
                        },
                        else => {},
                    }
                },
                else => return packet.asError(conn.client_capabilities),
            }
        }

        // Server ack
    }

    fn sendAuthSwitchResponse(
        conn: *Conn,
        auth: AuthPlugin,
        plugin_data: []const u8,
        config: *const Config,
    ) !void {
        var auth_response: FixedBytes(32) = .{};
        try generate_auth_response(
            auth,
            plugin_data,
            config.password,
            &auth_response,
        );
        try conn.sendBytesAsPacket(auth_response.get());
    }

    fn sendHandshakeResponse41(conn: *Conn, auth: AuthPlugin, auth_data: []const u8, config: *const Config) !void {
        var auth_response: FixedBytes(32) = .{};
        try generate_auth_response(
            auth,
            auth_data,
            config.password,
            &auth_response,
        );
        // TODO: support CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA
        // if (password_resp.len > 250) {
        //     resp_cap_flag |= constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA;
        // }
        const response: HandshakeResponse41 = .{
            .database = config.database,
            .client_flag = conn.client_capabilities,
            .character_set = config.collation,
            .username = config.username,
            .auth_response = auth_response.get(),
        };
        try conn.sendPacketUsingSmallPacketWriter(response);
    }

    fn sendPacketUsingSmallPacketWriter(conn: *Conn, packet: anytype) !void {
        std.debug.assert(conn.state == .connected);
        var writer = conn.writer;
        var small_packet_writer = stream_buffered.SmallPacketWriter.init(&writer, conn.generateSequenceId());
        try packet.write(&small_packet_writer);
        try small_packet_writer.flush();
    }

    fn sendBytesAsPacket(conn: *Conn, payload: []const u8) !void {
        std.debug.assert(conn.state == .connected);
        var writer = conn.writer;
        try packet_writer.writeUInt24(&writer, @truncate(payload.len));
        try packet_writer.writeUInt8(&writer, conn.generateSequenceId());
        try writer.write(payload);
        try writer.flush();
    }

    fn readPacket(conn: *Conn, allocator: std.mem.Allocator) !Packet {
        std.debug.assert(conn.state == .connected);
        const packet = try Packet.initFromReader(allocator, &conn.reader);
        try conn.updateSequenceId(packet);
        return packet;
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
        std.debug.assert(packet.sequence_id == conn.sequence_id);
        conn.sequence_id += 1;
    }

    fn generateSequenceId(conn: *Conn) u8 {
        const id = conn.sequence_id;
        conn.sequence_id += 1;
        return id;
    }
};

fn generate_auth_response(
    auth: AuthPlugin,
    auth_data: []const u8,
    password: []const u8,
    out: *FixedBytes(32),
) !void {
    switch (auth) {
        .caching_sha2_password => {
            if (password.len == 0) {
                try out.set("");
            } else {
                try out.set(&scrambleSHA256Password(auth_data, password));
            }
        },
        else => {
            std.log.warn("Unsupported auth plugin: {any}\n", .{auth_plugin});
            return error.UnsupportedAuthPlugin;
        },
    }
}

pub const PrepareResult = struct {
    packet: Packet,
    value: union(enum) {
        ok: PrepareOk,
        err: ErrorPacket,
    },

    pub fn deinit(p: *const PrepareResult, allocator: std.mem.Allocator) void {
        p.packet.deinit(allocator);
    }
};

pub const QueryResult = struct {
    packet: Packet,
    value: union(enum) {
        ok: OkPacket,
        err: ErrorPacket,
        rows: TextResultSet,
    },

    pub fn deinit(q: *const QueryResult, allocator: std.mem.Allocator) void {
        q.packet.deinit(allocator);
        switch (q.value) {
            .rows => |rows| rows.deinit(allocator),
            else => {},
        }
    }
};

pub const TextResultSet = struct {
    conn: *Conn,
    column_packets: []Packet,
    column_definitions: []ColumnDefinition41,

    fn init(allocator: std.mem.Allocator, conn: *Conn, column_count: u64) !TextResultSet {
        var t: TextResultSet = undefined;

        t.column_packets = try allocator.alloc(Packet, column_count);
        errdefer allocator.free(t.column_packets);
        t.column_definitions = try allocator.alloc(ColumnDefinition41, column_count);
        errdefer allocator.free(t.column_definitions);
        for (0..column_count) |i| {
            const packet = try conn.readPacket(allocator);
            errdefer packet.deinit(allocator);
            t.column_packets[i] = packet;
            t.column_definitions[i] = ColumnDefinition41.initFromPacket(&packet);
        }

        const eof_packet = try conn.readPacket(allocator);
        defer eof_packet.deinit(allocator);
        std.debug.assert(eof_packet.payload[0] == constants.EOF);

        t.conn = conn;
        return t;
    }

    fn deinit(t: *const TextResultSet, allocator: std.mem.Allocator) void {
        for (t.column_packets) |packet| {
            packet.deinit(allocator);
        }
        allocator.free(t.column_packets);
        allocator.free(t.column_definitions);
    }

    pub fn next(t: *TextResultSet, allocator: std.mem.Allocator) !?TextResultRow {
        const packet = try t.conn.readPacket(allocator);
        errdefer packet.deinit(allocator);

        return switch (packet.payload[0]) {
            constants.EOF => {
                packet.deinit(allocator);
                return null;
            },
            constants.ERR => return packet.asError(t.conn.client_capabilities),
            else => return .{
                .packet = packet,
                .text_result_set = t,
            },
        };
    }

    pub const TextResultRow = struct {
        packet: Packet,
        text_result_set: *const TextResultSet,

        pub fn scan(r: *const TextResultRow, dest: []?[]const u8) void {
            std.debug.assert(r.text_result_set.column_definitions.len == dest.len);

            var packet_reader = PacketReader.initFromPacket(&r.packet);
            for (dest) |*d| {
                d.* = blk: {
                    const first_byte = blk2: {
                        const byte_opt = packet_reader.peek();
                        std.debug.assert(byte_opt != null);
                        break :blk2 byte_opt.?;
                    };
                    if (first_byte == constants.TEXT_RESULT_ROW_NULL) {
                        packet_reader.forward_one();
                        break :blk null;
                    }
                    break :blk packet_reader.readLengthEncodedString();
                };
            }
        }

        pub fn deinit(text_result_set: *const TextResultRow, allocator: std.mem.Allocator) void {
            text_result_set.packet.deinit(allocator);
        }
    };
};

pub const ExecuteResponse = struct {
    packet: Packet,
    conn: *Conn,

    pub fn deinit(e: *const ExecuteResponse, allocator: std.mem.Allocator) void {
        e.packet.deinit(allocator);
    }

    pub fn ok(q: *const ExecuteResponse) !OkPacket {
        return switch (q.packet.payload[0]) {
            constants.OK => OkPacket.initFromPacket(&q.packet, q.conn.client_capabilities),
            constants.ERR => ErrorPacket.initFromPacket(false, &q.packet, q.conn.client_capabilities).asError(),
            else => error.RowsReturnedNotConsumed,
        };
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
        // std.debug.print("actual: {x}", .{ std.fmt.fmtSliceHexLower(&actual) });
        try std.testing.expectEqual(t.expected, actual);
    }
}
