const std = @import("std");
const PacketWriter = @import("./packet_writer.zig").PacketWriter;
const constants = @import("./../constants.zig");
const Config = @import("./../config.zig").Config;

// https://mariadb.com/kb/en/connection/#sslrequest-packet
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_ssl_request.html
pub const SSLRequest = struct {
    client_flag: u32, // capabilities
    max_packet_size: u32 = 0,
    character_set: u8,

    pub fn init(config: *const Config) SSLRequest {
        return .{
            .client_flag = config.capability_flags(),
            .character_set = config.collation,
        };
    }

    pub fn write(h: *const SSLRequest, writer: *PacketWriter) !void {
        try writer.writeInt(u32, h.client_flag);
        try writer.writeInt(u32, h.max_packet_size);
        try writer.writeInt(u8, h.character_set);
        try writer.write(&([_]u8{0} ** 23)); // filler
    }
};
