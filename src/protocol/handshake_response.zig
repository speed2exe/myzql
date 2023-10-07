// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_response.html
const Packet = @import("../packet.zig").Packet;
const packer_writer = @import("./packet_writer.zig");
const std = @import("std");
const constants = @import("../constants.zig");

pub const HandshakeResponse320 = struct {
    client_flags: u16,
    max_packet_size: u24,
    username: [:0]const u8,
    auth_response: [:0]const u8,
    database: [:0]const u8 = .{},

    pub fn write(h: HandshakeResponse320, writer: anytype, capabilities: u32) !void {
        try packer_writer.writeUInt16(writer, h.client_flags);
        try packer_writer.writeUInt24(writer, h.max_packet_size);
        try packer_writer.writeNullTerminatedString(writer, h.username);
        if ((capabilities & constants.CLIENT_CONNECT_WITH_DB) > 0) {
            try packer_writer.writeNullTerminatedString(writer, h.auth_response);
            try packer_writer.writeNullTerminatedString(writer, h.database);
        } else {
            try writer.write(h.auth_response);
        }
    }
};

pub const HandshakeResponse41 = struct {
    client_flags: u32,
    max_packet_size: u32,
    character_set: u8,
    username: [:0]const u8,
    auth_response: []const u8,
    database: [:0]const u8 = .{},
    client_plugin_name: [:0]const u8 = .{},
    key_values: []const [2][]const u8 = .{},
    zstd_compression_level: u8 = 0,

    pub fn write(h: HandshakeResponse41, writer: anytype, capabilities: u32) !void {
        try packer_writer.writeUInt32(writer, h.client_flags);
        try packer_writer.writeUInt24(writer, h.max_packet_size);
        try packer_writer.writeUInt8(writer, h.character_set);
        _ = try writer.write(&[0]u8 ** 23); // filler
        try packer_writer.writeNullTerminatedString(writer, h.username);

        if ((capabilities & constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) > 0) {
            try packer_writer.writeLengthEncodedString(writer, h.auth_response);
        } else {
            try packer_writer.writeUInt8(writer, h.auth_response_length);
            _ = try writer.write(h.auth_response);
        }
        if ((capabilities & constants.CLIENT_CONNECT_WITH_DB) > 0) {
            try packer_writer.writeNullTerminatedString(writer, h.database);
        }
        if ((capabilities & constants.CLIENT_PLUGIN_AUTH) > 0) {
            try packer_writer.writeNullTerminatedString(writer, h.client_plugin_name);
        }
        if ((capabilities & constants.CLIENT_CONNECT_ATTRS) > 0) {
            try packer_writer.writeLengthEncodedInteger(writer, h.key_values.len);
            for (h.key_values) |key_value| {
                try packer_writer.writeLengthEncodedString(writer, key_value[0]);
                try packer_writer.writeLengthEncodedString(writer, key_value[1]);
            }
        }
        if ((capabilities & constants.CLIENT_ZSTD_COMPRESSION_ALGORITHM) > 0) {
            try packer_writer.writeUInt8(writer, h.zstd_compression_level);
        }
    }
};
