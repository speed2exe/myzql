const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const auth = @import("./auth.zig");
const generate_auth_response = auth.generate_auth_response;
const AuthPlugin = auth.AuthPlugin;
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
const result = @import("./result.zig");
const QueryResult = result.QueryResult;
const PrepareResult = result.PrepareResult;
const PreparedStatement = result.PreparedStatement;
const TextResultRow = result.TextResultRow;
const BinaryResultRow = result.BinaryResultRow;
const ResultSet = result.ResultSet;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;

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
    pub fn query(conn: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !QueryResult(TextResultRow) {
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
                else => .{ .rows = blk: {
                    var packet_reader = PacketReader.initFromPacket(&response_packet);
                    const column_count = packet_reader.readLengthEncodedInteger();
                    std.debug.assert(packet_reader.finished());
                    break :blk try ResultSet(TextResultRow).init(allocator, conn, column_count);
                } },
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
                constants.OK => .{ .ok = try PreparedStatement.initFromPacket(&response_packet, conn, allocator) },
                else => return response_packet.asError(conn.client_capabilities),
            },
        };
    }

    pub fn execute(conn: *Conn, allocator: std.mem.Allocator, prep_stmt: *const PreparedStatement, params: anytype) !QueryResult(BinaryResultRow) {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        const execute_request: ExecuteRequest = .{
            .capabilities = conn.client_capabilities,
            .prep_stmt = prep_stmt,
        };
        try conn.sendPacketUsingSmallPacketWriterWithParams(execute_request, params);

        const response_packet = try conn.readPacket(allocator);
        return .{
            .packet = response_packet,
            .value = switch (response_packet.payload[0]) {
                constants.OK => .{ .ok = OkPacket.initFromPacket(&response_packet, conn.client_capabilities) },
                constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &response_packet, conn.client_capabilities) },
                else => .{ .rows = blk: {
                    var packet_reader = PacketReader.initFromPacket(&response_packet);
                    const column_count = packet_reader.readLengthEncodedInteger();
                    std.debug.assert(packet_reader.finished());
                    break :blk try ResultSet(BinaryResultRow).init(allocator, conn, column_count);
                } },
            },
        };
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

        var auth_plugin: AuthPlugin = undefined;
        var auth_data: [20]u8 = undefined;
        {
            const packet = try conn.readPacket(allocator);
            defer packet.deinit(allocator);

            const handshake_v10 = switch (packet.payload[0]) {
                constants.HANDSHAKE_V10 => HandshakeV10.initFromPacket(&packet, conn.client_capabilities),
                else => return packet.asError(conn.client_capabilities),
            };
            conn.server_capabilities = handshake_v10.capability_flags();

            auth_plugin = handshake_v10.get_auth_plugin();
            auth_data = handshake_v10.get_auth_data();

            // TODO: TLS handshake if enabled

            // send handshake response to server
            if (conn.hasCapability(constants.CLIENT_PROTOCOL_41)) {
                const auth_resp = try generate_auth_response(
                    handshake_v10.get_auth_plugin(),
                    &handshake_v10.get_auth_data(),
                    config.password,
                );
                const response: HandshakeResponse41 = .{
                    .database = config.database,
                    .client_flag = conn.client_capabilities,
                    .character_set = config.collation,
                    .username = config.username,
                    .auth_response = auth_resp.get(),
                };
                try conn.sendPacketUsingSmallPacketWriter(response);
            } else {
                // TODO: handle older protocol
                @panic("not implemented");
            }
        }

        while (true) {
            const packet = try conn.readPacket(allocator);
            defer packet.deinit(allocator);

            switch (packet.payload[0]) {
                constants.OK => return,
                constants.AUTH_SWITCH => {
                    const auth_switch = AuthSwitchRequest.initFromPacket(&packet);
                    auth_plugin = AuthPlugin.fromName(auth_switch.plugin_name);
                    const auth_resp = try generate_auth_response(auth_plugin, auth_switch.plugin_data, config.password);
                    try conn.sendBytesAsPacket(auth_resp.get());
                },
                constants.AUTH_MORE_DATA => {
                    // more auth exchange based on auth_method
                    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_authentication_methods.html
                    const more_data = packet.payload[1..];
                    switch (auth_plugin) {
                        .caching_sha2_password => {
                            switch (more_data[0]) {
                                auth.caching_sha2_password_fast_auth_success => {}, // success (do nothing, wait for next packet)
                                auth.caching_sha2_password_full_authentication_start => {
                                    // Full Authentication start

                                    // TODO: support TLS
                                    // // if TLS, send password as plain text
                                    // try conn.sendBytesAsPacket(config.password);

                                    // Request public key from server
                                    try conn.sendBytesAsPacket(&[_]u8{auth.caching_sha2_password_public_key_request});
                                    const pk_packet = try conn.readPacket(allocator);
                                    defer pk_packet.deinit(allocator);

                                    // Decode public key
                                    const decoded_pk = try auth.decodePublicKey(pk_packet.payload, allocator);
                                    defer decoded_pk.deinit(allocator);

                                    // Encrypt password with public key and send it to server
                                    const encrypted_pw = try auth.encryptPassword(allocator, config.password, &auth_data, &decoded_pk.value);
                                    defer allocator.free(encrypted_pw);
                                    try conn.sendBytesAsPacket(encrypted_pw);
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
    }

    fn sendPacketUsingSmallPacketWriter(conn: *Conn, packet: anytype) !void {
        std.debug.assert(conn.state == .connected);
        var small_packet_writer = stream_buffered.SmallPacketWriter.init(&conn.writer, conn.generateSequenceId());
        errdefer conn.writer.reset();
        try packet.write(&small_packet_writer);
        try small_packet_writer.flush();
    }

    fn sendPacketUsingSmallPacketWriterWithParams(conn: *Conn, packet: anytype, params: anytype) !void {
        std.debug.assert(conn.state == .connected);
        var small_packet_writer = stream_buffered.SmallPacketWriter.init(&conn.writer, conn.generateSequenceId());
        errdefer conn.writer.reset();
        try packet.writeWithParams(&small_packet_writer, params);
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

    pub fn readPacket(conn: *Conn, allocator: std.mem.Allocator) !Packet {
        std.debug.assert(conn.state == .connected);
        const packet = try Packet.initFromReader(allocator, &conn.reader);
        conn.sequence_id = packet.sequence_id + 1;
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

    fn generateSequenceId(conn: *Conn) u8 {
        const id = conn.sequence_id;
        conn.sequence_id += 1;
        return id;
    }
};
