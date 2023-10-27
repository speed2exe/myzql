const std = @import("std");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;

pub const ColumnDefinition41 = struct {
    catalog: []const u8,
    schema: []const u8,
    table: []const u8,
    org_table: []const u8,
    name: []const u8,
    org_name: []const u8,
    fixed_length_fields_length: u64,
    character_set: u16,
    column_length: u32,
    column_type: u8,
    flags: u16,
    decimals: u8,

    pub fn initFromPacket(packet: *const Packet) ColumnDefinition41 {
        var column_definition_41: ColumnDefinition41 = undefined;
        var reader = PacketReader.initFromPacket(packet);

        column_definition_41.catalog = reader.readLengthEncodedString();
        column_definition_41.schema = reader.readLengthEncodedString();
        column_definition_41.table = reader.readLengthEncodedString();
        column_definition_41.org_table = reader.readLengthEncodedString();
        column_definition_41.name = reader.readLengthEncodedString();
        column_definition_41.org_name = reader.readLengthEncodedString();
        column_definition_41.fixed_length_fields_length = reader.readLengthEncodedString();
        column_definition_41.character_set = reader.readUInt16();
        column_definition_41.column_length = reader.readUInt32();
        column_definition_41.column_type = reader.readUInt8();
        column_definition_41.flags = reader.readUInt16();
        column_definition_41.decimals = reader.readByte();

        std.debug.assert(reader.finished());
        return column_definition_41;
    }
};
