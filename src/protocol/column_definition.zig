const std = @import("std");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PayloadReader;

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

    pub fn init(packet: *const Packet) ColumnDefinition41 {
        var column_definition_41: ColumnDefinition41 = undefined;
        var reader = packet.reader();

        column_definition_41.catalog = reader.readLengthEncodedString();
        column_definition_41.schema = reader.readLengthEncodedString();
        column_definition_41.table = reader.readLengthEncodedString();
        column_definition_41.org_table = reader.readLengthEncodedString();
        column_definition_41.name = reader.readLengthEncodedString();
        column_definition_41.org_name = reader.readLengthEncodedString();
        column_definition_41.fixed_length_fields_length = reader.readLengthEncodedInteger();
        column_definition_41.character_set = reader.readInt(u16);
        column_definition_41.column_length = reader.readInt(u32);
        column_definition_41.column_type = reader.readInt(u8);
        column_definition_41.flags = reader.readInt(u16);
        column_definition_41.decimals = reader.readInt(u8);

        // https://mariadb.com/kb/en/result-set-packets/#column-definition-packet
        // According to mariadb, there seem to be extra 2 bytes at the end that is not being used
        std.debug.assert(reader.remained() == 2);

        return column_definition_41;
    }
};
