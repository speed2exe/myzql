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
        column_definition_41.init2(packet);
        return column_definition_41;
    }

    pub fn init2(c: *ColumnDefinition41, packet: *const Packet) void {
        var reader = packet.reader();

        c.catalog = reader.readLengthEncodedString();
        c.schema = reader.readLengthEncodedString();
        c.table = reader.readLengthEncodedString();
        c.org_table = reader.readLengthEncodedString();
        c.name = reader.readLengthEncodedString();
        c.org_name = reader.readLengthEncodedString();
        c.fixed_length_fields_length = reader.readLengthEncodedInteger();
        c.character_set = reader.readInt(u16);
        c.column_length = reader.readInt(u32);
        c.column_type = reader.readByte();
        c.flags = reader.readInt(u16);
        c.decimals = reader.readByte();

        // https://mariadb.com/kb/en/result-set-packets/#column-definition-packet
        // According to mariadb, there seem to be extra 2 bytes at the end that is not being used
        std.debug.assert(reader.remained() == 2);
    }
};
