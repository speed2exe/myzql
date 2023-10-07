// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_response.html
const packer_writer = @import("./packet_writer.zig");
const std = @import("std");
const constants = @import("../constants.zig");
const stream_buffered = @import("../stream_buffered.zig");

pub const HandshakeResponse320 = struct {
    client_flags: u16,
    max_packet_size: u24,
    username: [:0]const u8,
    auth_response: [:0]const u8,
    database: [:0]const u8 = "",

    pub fn write(h: HandshakeResponse320, writer: *stream_buffered.Writer, capabilities: u32) !void {
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
    client_flag: u32, // capabilities
    max_packet_size: u32 = 0,
    character_set: u8,
    username: [:0]const u8,
    auth_response: []const u8,
    database: [:0]const u8,
    client_plugin_name: [:0]const u8 = "",
    key_values: []const [2][]const u8 = &.{},
    zstd_compression_level: u8 = 0,

    pub fn write_as_packet(h: HandshakeResponse41, writer: *stream_buffered.Writer) !void {
        // Packet header
        const packet_size = payload_size(h);
        try packer_writer.writeUInt24(writer, packet_size);
        try packer_writer.writeUInt8(writer, 1); // sequence_id

        // payload
        try packer_writer.writeUInt32(writer, h.client_flag);
        try packer_writer.writeUInt32(writer, h.max_packet_size);
        try packer_writer.writeUInt8(writer, h.character_set);
        _ = try writer.write(&([_]u8{0} ** 23)); // filler
        try packer_writer.writeNullTerminatedString(writer, h.username);

        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) > 0) {
            try packer_writer.writeLengthEncodedString(writer, h.auth_response);
        } else {
            const length: u8 = @truncate(h.auth_response.len);
            try packer_writer.writeUInt8(writer, length);
            _ = try writer.write(h.auth_response);
        }
        if ((h.client_flag & constants.CLIENT_CONNECT_WITH_DB) > 0) {
            try packer_writer.writeNullTerminatedString(writer, h.database);
        }
        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH) > 0) {
            try packer_writer.writeNullTerminatedString(writer, h.client_plugin_name);
        }
        if ((h.client_flag & constants.CLIENT_CONNECT_ATTRS) > 0) {
            try packer_writer.writeLengthEncodedInteger(writer, h.key_values.len);
            for (h.key_values) |key_value| {
                try packer_writer.writeLengthEncodedString(writer, key_value[0]);
                try packer_writer.writeLengthEncodedString(writer, key_value[1]);
            }
        }
        if ((h.client_flag & constants.CLIENT_ZSTD_COMPRESSION_ALGORITHM) > 0) {
            try packer_writer.writeUInt8(writer, h.zstd_compression_level);
        }
        // todo: @panic("need to do auth switch");
    }

    pub fn payload_size(h: HandshakeResponse41) u24 {
        // client_flag: u32
        // max_packet_size: u32
        // character_set: u8,
        // filler: [23]u8,
        // username: [:0]const u8,
        var length: u24 = 4 + 4 + 1 + 23 + @as(u24, @truncate(h.username.len)) + 1;

        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) > 0) {
            length += packer_writer.lengthEncodedStringPayloadSize(h.auth_response.len);
        } else {
            length += @as(u24, @truncate(h.auth_response.len)) + 1;
        }
        if ((h.client_flag & constants.CLIENT_CONNECT_WITH_DB) > 0) {
            length += @as(u24, @truncate(h.database.len)) + 1;
        }
        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH) > 0) {
            length += @as(u24, @truncate(h.client_plugin_name.len)) + 1;
        }
        if ((h.client_flag & constants.CLIENT_CONNECT_ATTRS) > 0) {
            length += packer_writer.lengthEncodedIntegerPayloadSize(h.key_values.len);
            for (h.key_values) |key_value| {
                length += packer_writer.lengthEncodedStringPayloadSize(key_value[0].len);
                length += packer_writer.lengthEncodedStringPayloadSize(key_value[1].len);
            }
        }
        if ((h.client_flag & constants.CLIENT_ZSTD_COMPRESSION_ALGORITHM) > 0) {
            length += 1;
        }
        return length;
    }
};
