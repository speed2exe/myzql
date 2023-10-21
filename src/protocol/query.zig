const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const commands = @import("../commands.zig");
const constants = @import("../constants.zig");

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const TextProtocol = struct {
    query: []const u8,
    // TODO: support params

    pub fn write(h: *const TextProtocol, writer: *stream_buffered.SmallPacketWriter, capabilities: u32) !void {
        try packet_writer.writeUInt8(writer, commands.COM_QUERY);
        if (capabilities & commands.CLIENT_PROTOCOL_41) != 0 {
            try packet_writer.writeUInt32LE(writer, 0);
        }
    }
};
