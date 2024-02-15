const std = @import("std");
const Config = @import("./config.zig").Config;
const constants = @import("./constants.zig");
const auth = @import("./auth.zig");
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
const PacketReader = protocol.packet_reader.PacketReader;
const PacketWriter = protocol.packet_writer.PacketWriter;
const result = @import("./result.zig");
const QueryResult = result.QueryResult;
const PrepareResult = result.PrepareResult;
const PreparedStatement = result.PreparedStatement;
const TextResultData = result.TextResultData;
const BinaryResultData = result.BinaryResultData;
const ResultSet = result.ResultSet;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;
const EofPacket = protocol.generic_response.EofPacket;

const max_packet_size = 1 << 24 - 1;

// TODO: make this adjustable during compile time
const buffer_size: usize = 4096;

pub const Conn = struct {
    stream: std.net.Stream,
    reader: PacketReader,
    writer: PacketWriter,
    capabilities: u32,
    sequence_id: u8,

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html
    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Conn {
        var conn: Conn = blk: {
            const stream = try std.net.tcpConnectToAddress(config.address);
            break :blk .{
                .stream = stream,
                .reader = try PacketReader.init(stream, allocator),
                .writer = try PacketWriter.init(stream, allocator),
                .capabilities = undefined, // not known until we get the first packet
                .sequence_id = undefined, // not known until we get the first packet
            };
        };
        errdefer conn.deinit();

        const auth_plugin, const auth_data = blk: {
            const packet = try conn.readPacket();
            std.debug.print("packet: {s}\n", .{packet.payload});
            const handshake_v10 = switch (packet.payload[0]) {
                constants.HANDSHAKE_V10 => HandshakeV10.init(&packet),
                else => return packet.asError(),
            };
            conn.capabilities = handshake_v10.capability_flags() & config.capability_flags();

            if (conn.capabilities & constants.CLIENT_PROTOCOL_41 == 0) {
                std.log.err("protocol older than 4.1 is not supported\n", .{});
                return error.UnsupportedProtocol;
            }

            break :blk .{ handshake_v10.get_auth_plugin(), handshake_v10.get_auth_data() };
        };

        // TODO: TLS handshake if enabled

        // more auth exchange based on auth_method
        // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_authentication_methods.html
        switch (auth_plugin) {
            .caching_sha2_password => try conn.auth_caching_sha2_password(allocator, &auth_data, config),
            .mysql_native_password => try conn.auth_mysql_native_password(&auth_data, config),
            .sha256_password => try conn.auth_sha256_password(allocator, &auth_data, config),
            else => {
                std.log.warn("Unsupported auth plugin: {any}\n", .{auth_plugin});
                return error.UnsupportedAuthPlugin;
            },
        }

        return conn;
    }

    pub fn deinit(c: *const Conn) void {
        c.stream.close();
        c.reader.deinit();
        c.writer.deinit();
    }

    pub fn ping(c: *Conn) !void {
        try c.writeBytesAsPacket(&[_]u8{constants.COM_PING});
        const packet = try c.readPacket();
        switch (packet.payload[0]) {
            constants.OK => _ = OkPacket.init(&packet, c.capabilities),
            else => return packet.asError(),
        }
    }

    // TODO: add options
    /// caller must consume the result by switching on the result's value
    pub fn query(conn: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !QueryResult(TextResultData) {
        std.debug.assert(conn.state == .connected);
        const query_request: QueryRequest = .{ .query = query_string };
        conn.writer.reset();
        conn.writePacket(query_request);
        try conn.sendPacketUsingSmallPacketWriter(query_request);
        return QueryResult(TextResultData).init(conn, allocator);
    }

    // TODO: add options
    pub fn prepare(conn: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !PrepareResult {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        const prepare_request: PrepareRequest = .{ .query = query_string };
        try conn.sendPacketUsingSmallPacketWriter(prepare_request);
        return PrepareResult.init(conn, allocator);
    }

    pub fn execute(conn: *Conn, allocator: std.mem.Allocator, prep_stmt: *const PreparedStatement, params: anytype) !QueryResult(BinaryResultData) {
        std.debug.assert(conn.state == .connected);
        conn.sequence_id = 0;
        const execute_request: ExecuteRequest = .{
            .capabilities = conn.capabilities,
            .prep_stmt = prep_stmt,
        };
        try conn.sendPacketUsingSmallPacketWriterWithParams(execute_request, params);
        return QueryResult(BinaryResultData).init(conn, allocator);
    }

    fn auth_mysql_native_password(conn: *Conn, auth_data: *const [20]u8, config: *const Config) !void {
        const auth_resp = auth.scramblePassword(auth_data, config.password);
        const response = HandshakeResponse41.init(.mysql_native_password, config, &auth_resp);
        try conn.writePacket(response);

        const packet = try conn.readPacket();
        return switch (packet.payload[0]) {
            constants.OK => {},
            else => packet.asError(),
        };
    }

    fn auth_sha256_password(conn: *Conn, allocator: std.mem.Allocator, auth_data: *const [20]u8, config: *const Config) !void {
        // TODO: if there is already a pub key, skip requesting it
        const response = HandshakeResponse41.init(.sha256_password, config, &[_]u8{auth.sha256_password_public_key_request});
        try conn.writePacket(response);

        const pk_packet = try conn.readPacket();

        // Decode public key
        const decoded_pk = try auth.decodePublicKey(pk_packet.payload, allocator);
        defer decoded_pk.deinit(allocator);

        const enc_pw = try auth.encryptPassword(allocator, config.password, auth_data, &decoded_pk.value);
        defer allocator.free(enc_pw);

        try conn.writeBytesAsPacket(enc_pw);

        const resp_packet = try conn.readPacket();
        return switch (resp_packet.payload[0]) {
            constants.OK => {},
            else => resp_packet.asError(),
        };
    }

    fn auth_caching_sha2_password(conn: *Conn, allocator: std.mem.Allocator, auth_data: *const [20]u8, config: *const Config) !void {
        const auth_resp = auth.scrambleSHA256Password(auth_data, config.password);
        const response = HandshakeResponse41.init(.caching_sha2_password, config, &auth_resp);
        try conn.writePacket(&response);

        while (true) {
            const packet = try conn.readPacket();
            switch (packet.payload[0]) {
                constants.OK => return,
                constants.AUTH_MORE_DATA => {
                    const more_data = packet.payload[1..];
                    switch (more_data[0]) {
                        auth.caching_sha2_password_fast_auth_success => {}, // success (do nothing, wait for next packet)
                        auth.caching_sha2_password_full_authentication_start => {
                            // Full Authentication start

                            // TODO: support TLS
                            // // if TLS, send password as plain text
                            // try conn.sendBytesAsPacket(config.password);

                            try conn.writeBytesAsPacket(&[_]u8{auth.caching_sha2_password_public_key_request});
                            const pk_packet = try conn.readPacket();

                            // Decode public key
                            const decoded_pk = try auth.decodePublicKey(pk_packet.payload, allocator);
                            defer decoded_pk.deinit(allocator);

                            // Encrypt password
                            const enc_pw = try auth.encryptPassword(allocator, config.password, auth_data, &decoded_pk.value);
                            defer allocator.free(enc_pw);

                            try conn.writeBytesAsPacket(enc_pw);
                        },
                        else => return error.UnsupportedCachingSha2PasswordMoreData,
                    }
                },
                else => return packet.asError(),
            }
        }
    }

    inline fn readPacket(conn: *Conn) !Packet {
        const packet = try conn.reader.readPacket();
        conn.sequence_id = packet.sequence_id;
        return packet;
    }

    inline fn writePacket(conn: *Conn, packet: anytype) !void {
        try conn.writer.writePacket(conn.generateSequenceId(), packet);
    }

    inline fn writeBytesAsPacket(conn: *Conn, packet: anytype) !void {
        try conn.writer.writeBytesAsPacket(conn.generateSequenceId(), packet);
    }

    inline fn generateSequenceId(conn: *Conn) u8 {
        const sequence_id = conn.sequence_id;
        conn.sequence_id += 1;
        return sequence_id;
    }
};
