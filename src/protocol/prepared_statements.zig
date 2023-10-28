const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;
const QueryParam = @import("./text_command.zig").QueryParam;

pub const BinaryParam = struct {
    type_and_flag: [2]u8, // LSB: type, MSB: flag
    name: []const u8,
    raw: []const u8,
};

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

pub const ExecuteResquest = struct {
    prep_ok: *const PrepareOk,
    flags: u8 = 0, // Cursor type
    iteration_count: u32 = 1, // Always 1
    new_params_bind_flag: u8 = 1,

    params: []const BinaryParam = &.{},
    attributes: []const BinaryParam = &.{},

    pub fn write(e: *const ExecuteResquest, writer: anytype, capabilities: u32) !void {
        std.debug.assert(e.prep_ok.num_params == e.params.len);

        try packet_writer.writeUInt8(writer, constants.COM_STMT_EXECUTE);
        try packet_writer.writeUInt32(writer, e.prep_ok.statement_id);
        try packet_writer.writeUInt8(writer, e.flags);
        try packet_writer.writeUInt32(writer, e.iteration_count);

        const has_attributes_to_write = (capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) and e.attributes.len > 0;
        if (e.prep_ok.num_params > 0 || has_attributes_to_write) {
            if (has_attributes_to_write) {
                try packet_writer.writeLengthEncodedInteger(writer, e.attributes.len + e.prep_ok.num_params);
            }

            // Write Null Bitmap
            if (has_attributes_to_write) {
                try writeNullBitmap(e.params, e.attributes, writer);
            } else {
                try writeNullBitmap(e.params, &.{}, writer);
            }

            // If a statement is re-executed without changing the params types,
            // the types do not need to be sent to the server again.
            // send type to server (0 / 1)
            try packet_writer.writeLengthEncodedInteger(writer, e.new_params_bind_flag);
            if (e.new_params_bind_flag > 0) {
                for (e.params) |b| {
                    try writer.write(b.type_and_flag);
                    if (capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) {
                        try packet_writer.writeLengthEncodedString(writer, b.name);
                    }
                }
                if (has_attributes_to_write) {
                    for (e.attributes) |b| {
                        try writer.write(b.type_and_flag);
                        try packet_writer.writeLengthEncodedString(writer, b.name);
                    }
                }
            }

            // Write params as binary values
            for (e.params) |b| {
                writer.write(b.raw);
            }
            if (has_attributes_to_write) {
                for (e.attributes) |b| {
                    writer.write(b.raw);
                }
            }
        }
    }
};

fn writeNullBitmap(params: []const BinaryParam, attributes: []const BinaryParam, writer: anytype) !void {
    const byte_count = (params.len + attributes.len + 7) / 8;
    for (0..byte_count) |i| {
        const start = i * 8;
        const end = (i + 1) * 8;
        var byte: u8 = undefined;
        if (params.len >= end) {
            byte = nullBits1(params[start..]);
        } else if (start >= params.len) {
            byte = nullBits1(attributes[(start - params.len)..]);
        } else {
            byte = nullBits2(params[start..], attributes[(end - params.len)..]);
        }

        // const byte = nullBits(params[i * 8 ..]);
        try packet_writer.writeUInt8(writer, byte);
    }
}

pub fn nullBits1(params: []const BinaryParam) u8 {
    const final_params = if (params.len > 8) params[0..8] else params;

    var byte: u8 = 0;
    var current_bit: u8 = 1;
    for (final_params) |p| {
        if (p.type_and_flag & 0x80 == 0) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }
    return byte;
}

pub fn nullBits2(params1: []const BinaryParam, params2: []const BinaryParam) u8 {
    const final_params = if (params1.len > 8) params1[0..8] else params1;
    const final_attributes = if (params2.len > 8) params2[0..8] else params2;

    var byte: u8 = 0;
    var current_bit: u8 = 1;
    for (final_params) |p| {
        if (p.type_and_flag & 0x80 == 0) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }
    for (final_attributes) |p| {
        if (p.type_and_flag & 0x80 == 0) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }
    return byte;
}

// TODO: test case
