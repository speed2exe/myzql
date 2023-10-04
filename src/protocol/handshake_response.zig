// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_response.html
const Packet = @import("../packet.zig").Packet;
const packer_writer = @import("./packet_writer.zig");
const std = @import("std");
const constants = @import("../constants.zig");

pub const HandshakeResponse320 = struct {
    client_flags: u16,
    max_packet_size: u24,
    username: [:0]const u8,
    auth_response: ?[:0]const u8,
    database: ?[:0]const u8,

    pub fn write(h: HandshakeResponse320, writer: anytype, capabilities: u32) !void {
        try packer_writer.writeUInt16(writer, h.client_flags);
        try packer_writer.writeUInt24(writer, h.max_packet_size);
        try packer_writer.writeNullTerminatedString(writer, h.username);
        if ((capabilities & constants.CLIENT_CONNECT_WITH_DB) > 0) {
            try writer.writeByte(0);
            try writer.write(h.database);
        }
        // TODO: continue
    }
};

pub const HandshakeResponse41 = struct {
    client_flags: u32,
    max_packet_size: u32,
    character_set: u8,
    filler: [23]u8 = .{0} ** 23,
    username: [:0]const u8,
    auth_response_length: ?u8,
    auth_response: []const u8,
    database: ?[:0]const u8,
    client_plugin_name: ?[:0]const u8,
    length_of_all_key_values: ?u64,
    key_values: ?[]const [2][]const u8,
    zstd_compression_level: ?u8,
};
