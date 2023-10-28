const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const PrepareRequest = struct {
    query: []const u8,

    pub fn write(q: *const PrepareRequest, writer: *stream_buffered.SmallPacketWriter) !void {
        try packet_writer.writeUInt8(writer, constants.COM_STMT_PREPARE);
        try writer.write(q.query);
    }
};

pub const PrepareOk = struct {
    status: u8,
    statement_id: u32,
    num_columns: u16,
    num_params: u16,

    warning_count: ?u16,
    metadata_follows: ?u8,

    pub fn initFromPacket(packet: *const Packet, capabilities: u32) PrepareOk {
        var prepare_ok_packet: PrepareOk = undefined;

        var reader = PacketReader.initFromPacket(packet);
        prepare_ok_packet.status = reader.readByte();
        prepare_ok_packet.statement_id = reader.readUInt32();
        prepare_ok_packet.num_columns = reader.readUInt16();
        prepare_ok_packet.num_params = reader.readUInt16();

        // Reserved 1 byte
        const b = reader.readByte();
        std.debug.assert(b == 0);

        if (reader.finished()) {
            prepare_ok_packet.warning_count = null;
            prepare_ok_packet.metadata_follows = null;
            return prepare_ok_packet;
        }

        prepare_ok_packet.warning_count = reader.readUInt16();
        if (capabilities & constants.CLIENT_OPTIONAL_RESULTSET_METADATA > 0) {
            prepare_ok_packet.metadata_follows = reader.readByte();
        } else {
            prepare_ok_packet.metadata_follows = null;
        }
        return prepare_ok_packet;
    }
};
