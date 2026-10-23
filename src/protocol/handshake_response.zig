// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_response.html
// https://mariadb.com/kb/en/connection/#client-handshake-response
const packer_writer = @import("./packet_writer.zig");
const std = @import("std");
const constants = @import("../constants.zig");
const Config = @import("../config.zig").Config;
const AuthPlugin = @import("../auth.zig").AuthPlugin;
const PacketWriter = @import("./packet_writer.zig").PacketWriter;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_ssl_request.html
/// Sent instead of the `HandshakeResponse41` when the client wants TLS: it
/// carries the first 32 bytes of the handshake response and nothing else, so
/// that the server knows to start the TLS handshake before the remaining
/// handshake response is sent (encrypted).
pub const SslRequest = struct {
    client_flag: u32, // capabilities, must include CLIENT_SSL
    max_packet_size: u32 = 0, // TODO: support configurable max packet size
    character_set: u8,

    pub fn init(config: *const Config) SslRequest {
        return .{
            .client_flag = config.capability_flags(),
            .character_set = config.collation,
        };
    }

    pub fn write(s: *const SslRequest, writer: *PacketWriter) !void {
        try writer.writeInt(u32, s.client_flag);
        try writer.writeInt(u32, s.max_packet_size);
        try writer.writeInt(u8, s.character_set);
        try writer.write(&(@as([23]u8, @splat(0)))); // filler
    }
};

pub const HandshakeResponse41 = struct {
    client_flag: u32, // capabilities
    max_packet_size: u32 = 0, // TODO: support configurable max packet size
    character_set: u8,
    username: [:0]const u8,
    auth_response: []const u8,
    database: [:0]const u8,
    client_plugin_name: [:0]const u8,
    key_values: []const [2][]const u8 = &.{},
    zstd_compression_level: u8 = 0,

    pub fn init(comptime auth_plugin: AuthPlugin, config: *const Config, auth_resp: []const u8) HandshakeResponse41 {
        return .{
            .database = config.database,
            .client_flag = config.capability_flags(),
            .character_set = config.collation,
            .username = config.username,
            .auth_response = auth_resp,
            .client_plugin_name = auth_plugin.toName(),
        };
    }

    pub fn write(h: *const HandshakeResponse41, writer: *PacketWriter) !void {
        try writer.writeInt(u32, h.client_flag);

        try writer.writeInt(u32, h.max_packet_size);
        try writer.writeInt(u8, h.character_set);
        try writer.write(&(@as([23]u8, @splat(0)))); // filler
        try writer.writeNullTerminatedString(h.username);

        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) > 0) {
            try writer.writeLengthEncodedString(h.auth_response);
        } else if ((h.client_flag & constants.CLIENT_SECURE_CONNECTION) > 0) {
            const length: u8 = @intCast(h.auth_response.len);
            try writer.writeInt(u8, length);
            try writer.write(h.auth_response);
        } else {
            try writer.write(h.auth_response);
            try writer.writeInt(u8, 0);
        }
        if ((h.client_flag & constants.CLIENT_CONNECT_WITH_DB) > 0) {
            try writer.writeNullTerminatedString(h.database);
        }
        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH) > 0) {
            try writer.writeNullTerminatedString(h.client_plugin_name);
        }
        if ((h.client_flag & constants.CLIENT_CONNECT_ATTRS) > 0) {
            try writer.writeLengthEncodedInteger(h.key_values.len);
            for (h.key_values) |key_value| {
                try writer.writeLengthEncodedString(key_value[0]);
                try writer.writeLengthEncodedString(key_value[1]);
            }
        }
        if ((h.client_flag & constants.CLIENT_ZSTD_COMPRESSION_ALGORITHM) > 0) {
            try writer.writeInt(u8, h.zstd_compression_level);
        }
    }
};

const testing = std.testing;

const ssl_request_filler: [23]u8 = @splat(0);

test "SslRequest - wire format" {
    const config: Config = .{ .database = "db", .ssl = true, .collation = constants.utf8mb4_bin };

    var writer = PacketWriter.init(testing.allocator, undefined);
    defer writer.deinit();

    // The transport is only used by `flush`, so it can stay undefined here
    try SslRequest.init(&config).write(&writer);

    // capabilites, max packet size, collation, 23 byte filler
    try testing.expectEqual(32, writer.pos);
    const client_flag = std.mem.readInt(u32, writer.buf[0..4], .little);
    try testing.expectEqual(config.capability_flags(), client_flag);
    try testing.expect(client_flag & constants.CLIENT_SSL != 0);
    try testing.expectEqual(0, std.mem.readInt(u32, writer.buf[4..8], .little));
    try testing.expectEqual(constants.utf8mb4_bin, writer.buf[8]);
    try testing.expectEqualSlices(u8, &ssl_request_filler, writer.buf[9..32]);
}
