// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_response.html
const packer_writer = @import("./packet_writer.zig");
const std = @import("std");
const constants = @import("../constants.zig");
const stream_buffered = @import("../stream_buffered.zig");

pub const HandshakeResponse41 = struct {
    client_flag: u32, // capabilities
    max_packet_size: u32 = 0,
    character_set: u8,
    username: [:0]const u8,
    auth_response: []const u8,
    database: [:0]const u8,
    client_plugin_name: [:0]const u8,
    key_values: []const [2][]const u8 = &.{},
    zstd_compression_level: u8 = 0,

    pub fn write(h: *const HandshakeResponse41, writer: *stream_buffered.SmallPacketWriter) !void {
        try packer_writer.writeUInt32(writer, h.client_flag);
        try packer_writer.writeUInt32(writer, h.max_packet_size);
        try packer_writer.writeUInt8(writer, h.character_set);
        try writer.write(&([_]u8{0} ** 23)); // filler
        try packer_writer.writeNullTerminatedString(writer, h.username);

        if ((h.client_flag & constants.CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) > 0) {
            try packer_writer.writeLengthEncodedString(writer, h.auth_response);
        } else {
            const length: u8 = @truncate(h.auth_response.len);
            try packer_writer.writeUInt8(writer, length);
            try writer.write(h.auth_response);
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
    }
};
