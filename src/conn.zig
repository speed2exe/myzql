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
const TextResultData = result.TextResultRow;
const BinaryResultData = result.BinaryResultRow;
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
    server_capabilities: u32,
    client_capabilities: u32,
    sequence_id: u8,

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html
    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Conn {
        var conn: Conn = blk: {
            const stream = try std.net.tcpConnectToAddress(config.address);
            break :blk .{
                .stream = stream,
                .reader = try PacketReader.init(stream, allocator),
                .writer = try PacketWriter.init(stream, allocator),
                .client_capabilities = config.capability_flags(),
                .server_capabilities = undefined, // not known until we get the first packet
                .sequence_id = undefined, // not known until we get the first packet
            };
        };
        errdefer conn.deinit();

        const auth_plugin, const auth_data = blk: {
            const packet = try conn.readPacket();
            const handshake_v10 = switch (packet.payload[0]) {
                constants.HANDSHAKE_V10 => HandshakeV10.init(&packet),
                else => return packet.asError(),
            };
            conn.server_capabilities = handshake_v10.capability_flags() & config.capability_flags();

            if (conn.server_capabilities & constants.CLIENT_PROTOCOL_41 == 0) {
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
        c.sequence_id = 0;
        try c.writeBytesAsPacket(&[_]u8{constants.COM_PING});
        try c.writer.flush();
        const packet = try c.readPacket();

        switch (packet.payload[0]) {
            constants.OK => _ = OkPacket.init(&packet, c.client_capabilities),
            else => return packet.asError(),
        }
    }

    // TODO: add options
    pub fn query(c: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !QueryResult(TextResultData) {
        c.sequence_id = 0;
        const query_req: QueryRequest = .{ .query = query_string };
        try c.writePacket(query_req);
        try c.writer.flush();
        return QueryResult(TextResultData).init(c, allocator);
    }

    // TODO: add options
    pub fn prepare(c: *Conn, allocator: std.mem.Allocator, query_string: []const u8) !PrepareResult {
        c.sequence_id = 0;
        const prepare_request: PrepareRequest = .{ .query = query_string };
        try c.writePacket(prepare_request);
        try c.writer.flush();
        return PrepareResult.init(c, allocator);
    }

    pub fn execute(c: *Conn, allocator: std.mem.Allocator, prep_stmt: *const PreparedStatement, params: anytype) !QueryResult(BinaryResultData) {
        c.sequence_id = 0;
        const execute_request: ExecuteRequest = .{
            .capabilities = c.client_capabilities,
            .prep_stmt = prep_stmt,
        };
        try c.writePacketWithParam(execute_request, params);
        try c.writer.flush();
        return QueryResult(BinaryResultData).init(c, allocator);
    }

    fn auth_mysql_native_password(c: *Conn, auth_data: *const [20]u8, config: *const Config) !void {
        const auth_resp = auth.scramblePassword(auth_data, config.password);
        const response = HandshakeResponse41.init(.mysql_native_password, config, &auth_resp);
        try c.writePacket(response);
        try c.writer.flush();

        const packet = try c.readPacket();
        return switch (packet.payload[0]) {
            constants.OK => {},
            else => packet.asError(),
        };
    }

    fn auth_sha256_password(c: *Conn, allocator: std.mem.Allocator, auth_data: *const [20]u8, config: *const Config) !void {
        // TODO: if there is already a pub key, skip requesting it
        const response = HandshakeResponse41.init(.sha256_password, config, &[_]u8{auth.sha256_password_public_key_request});
        try c.writePacket(response);
        try c.writer.flush();

        const pk_packet = try c.readPacket();

        // Decode public key
        const decoded_pk = try auth.decodePublicKey(pk_packet.payload, allocator);
        defer decoded_pk.deinit(allocator);

        const enc_pw = try auth.encryptPassword(allocator, config.password, auth_data, &decoded_pk.value);
        defer allocator.free(enc_pw);

        try c.writeBytesAsPacket(enc_pw);
        try c.writer.flush();

        const resp_packet = try c.readPacket();
        return switch (resp_packet.payload[0]) {
            constants.OK => {},
            else => resp_packet.asError(),
        };
    }

    fn auth_caching_sha2_password(c: *Conn, allocator: std.mem.Allocator, auth_data: *const [20]u8, config: *const Config) !void {
        const auth_resp = auth.scrambleSHA256Password(auth_data, config.password);
        const response = HandshakeResponse41.init(.caching_sha2_password, config, &auth_resp);
        try c.writePacket(&response);
        try c.writer.flush();

        while (true) {
            const packet = try c.readPacket();
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

                            try c.writeBytesAsPacket(&[_]u8{auth.caching_sha2_password_public_key_request});
                            try c.writer.flush();
                            const pk_packet = try c.readPacket();

                            // Decode public key
                            const decoded_pk = try auth.decodePublicKey(pk_packet.payload, allocator);
                            defer decoded_pk.deinit(allocator);

                            // Encrypt password
                            const enc_pw = try auth.encryptPassword(allocator, config.password, auth_data, &decoded_pk.value);
                            defer allocator.free(enc_pw);

                            try c.writeBytesAsPacket(enc_pw);
                            try c.writer.flush();
                        },
                        else => return error.UnsupportedCachingSha2PasswordMoreData,
                    }
                },
                else => return packet.asError(),
            }
        }
    }

    pub inline fn readPacket(c: *Conn) !Packet {
        const packet = try c.reader.readPacket();
        c.sequence_id = packet.sequence_id + 1;
        return packet;
    }

    inline fn writePacket(c: *Conn, packet: anytype) !void {
        try c.writer.writePacket(c.generateSequenceId(), packet);
    }

    inline fn writePacketWithParam(c: *Conn, packet: anytype, params: anytype) !void {
        try c.writer.writePacketWithParams(c.generateSequenceId(), packet, params);
    }

    inline fn writeBytesAsPacket(c: *Conn, packet: anytype) !void {
        try c.writer.writeBytesAsPacket(c.generateSequenceId(), packet);
    }

    inline fn generateSequenceId(c: *Conn) u8 {
        const sequence_id = c.sequence_id;
        c.sequence_id += 1;
        return sequence_id;
    }
};
