const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;
const PreparedStatement = @import("./../result.zig").PreparedStatement;
const ColumnDefinition41 = @import("./column_definition.zig").ColumnDefinition41;
const helper = @import("./../helper.zig");

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

pub const BinaryParam = struct {
    type_and_flag: [2]u8, // LSB: type, MSB: flag
    name: []const u8,
    raw: ?[]const u8,
};

pub const ExecuteRequest = struct {
    prep_stmt: *const PreparedStatement,

    capabilities: u32,
    flags: u8 = 0, // Cursor type
    iteration_count: u32 = 1, // Always 1
    new_params_bind_flag: u8 = 1,

    attributes: []const BinaryParam = &.{},

    pub fn writeWithParams(e: *const ExecuteRequest, writer: anytype, params: anytype) !void {
        try packet_writer.writeUInt8(writer, constants.COM_STMT_EXECUTE);
        try packet_writer.writeUInt32(writer, e.prep_stmt.prep_ok.statement_id);
        try packet_writer.writeUInt8(writer, e.flags);
        try packet_writer.writeUInt32(writer, e.iteration_count);

        const has_attributes_to_write = (e.capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) and e.attributes.len > 0;
        const param_count = e.prep_stmt.prep_ok.num_params;
        if (param_count > 0 or has_attributes_to_write) {
            if (has_attributes_to_write) {
                try packet_writer.writeLengthEncodedInteger(writer, e.attributes.len + param_count);
            }

            // Write Null Bitmap
            if (has_attributes_to_write) {
                try writeNullBitmap(params, e.attributes, writer);
            } else {
                try writeNullBitmap(params, &.{}, writer);
            }

            // If a statement is re-executed without changing the params types,
            // the types do not need to be sent to the server again.
            // send type to server (0 / 1)
            try packet_writer.writeLengthEncodedInteger(writer, e.new_params_bind_flag);
            if (e.new_params_bind_flag > 0) {
                for (e.prep_stmt.params) |col_def| {
                    try packet_writer.writeUInt8(writer, col_def.column_type);
                    try packet_writer.writeUInt8(writer, 0);
                    if (e.capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) {
                        try packet_writer.writeLengthEncodedString(writer, col_def.name);
                    }
                }
                if (has_attributes_to_write) {
                    for (e.attributes) |b| {
                        try writer.write(&b.type_and_flag);
                        try packet_writer.writeLengthEncodedString(writer, b.name);
                    }
                }
            }

            // TODO: Write params and attr as binary values
            // Write params as binary values
            inline for (params, e.prep_stmt.params) |param, *col_def| {
                try helper.encodeBinaryParam(param, col_def, writer);
            }
            if (has_attributes_to_write) {
                for (e.attributes) |b| {
                    try writeAttr(b, writer);
                }
            }
        }
    }
};

fn writeAttr(param: BinaryParam, writer: anytype) !void {
    _ = writer;
    _ = param;
    @panic("TODO: support mysql attributes");
}

fn writeNullBitmap(params: anytype, attributes: []const BinaryParam, writer: anytype) !void {
    const byte_count = (params.len + attributes.len + 7) / 8;
    for (0..byte_count) |i| {
        const start = i * 8;
        const end = (i + 1) * 8;

        const byte: u8 = blk: {
            if (params.len >= end) {
                break :blk nullBitsParams(params, start);
            } else if (start >= params.len) {
                break :blk nullBitsAttrs(attributes[(start - params.len)..]);
            } else {
                break :blk nullBitsParamsAttrs(params, start, attributes);
            }
        };

        // [1,1,1,1] [1,1,1]
        // start = 0, end = 8
        try packet_writer.writeUInt8(writer, byte);
    }
}

pub fn nullBitsParams(params: anytype, start: usize) u8 {
    var byte: u8 = 0;

    var current_bit: u8 = 1;

    const end = comptime if (params.len > 8) 8 else params.len;
    inline for (params, 0..) |param, i| {
        if (i >= end) break;
        if (i >= start) {
            if (isNull(param)) byte |= current_bit;
            current_bit <<= 1;
        }
    }

    return byte;
}

pub fn nullBitsAttrs(attrs: []const BinaryParam) u8 {
    const final_attrs = if (attrs.len > 8) attrs[0..8] else attrs;

    var byte: u8 = 0;
    var current_bit: u8 = 1;
    for (final_attrs) |p| {
        if (p.raw == null) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }
    return byte;
}

pub fn nullBitsParamsAttrs(params: anytype, start: usize, attrs: []const BinaryParam) u8 {
    const final_attributes = if (attrs.len > 8) attrs[0..8] else attrs;

    var byte: u8 = 0;
    var current_bit: u8 = 1;

    inline for (params, 0..) |param, i| {
        if (i >= start) {
            if (isNull(param)) byte |= current_bit;
            current_bit <<= 1;
        }
    }

    for (final_attributes) |p| {
        if (p.raw == null) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }

    return byte;
}

inline fn isNull(param: anytype) bool {
    return switch (@typeInfo(@TypeOf(param))) {
        inline .Optional => param == null,
        inline .Null => param == null,
        inline else => false,
    };
}

fn nonNullBinaryParam() BinaryParam {
    return .{
        .type_and_flag = .{ 0x00, 0x00 },
        .name = "foo",
        .raw = "bar",
    };
}

fn nullBinaryParam() BinaryParam {
    return .{
        .type_and_flag = .{ 0x00, 0x00 },
        .name = "hello",
        .raw = null,
    };
}

test "writeNullBitmap" {
    const some_param = nonNullBinaryParam();
    const null_param = nullBinaryParam();

    const tests = .{
        .{
            .params = &.{1},
            .attributes = &.{some_param},
            .expected = &[_]u8{0b00000000},
        },
        .{
            .params = &.{ null, @as(?u8, null) },
            .attributes = &.{null_param},
            .expected = &[_]u8{0b00000111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null },
            .attributes = &.{},
            .expected = &[_]u8{0b11111111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null, null },
            .attributes = &.{},
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{},
            .attributes = &.{ null_param, null_param, null_param, null_param, null_param, null_param, null_param, null_param, null_param },
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{},
            .attributes = &.{ null_param, null_param, null_param, null_param, null_param, null_param, null_param, null_param },
            .expected = &[_]u8{0b11111111},
        },
        .{
            .params = &.{},
            .attributes = &.{ null_param, null_param, null_param, null_param, null_param, null_param, null_param },
            .expected = &[_]u8{0b01111111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null },
            .attributes = &.{null_param},
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{ null, null, null, null, null, null, null },
            .attributes = &.{ null_param, null_param },
            .expected = &[_]u8{ 0b11111111, 0b00000001 },
        },
        .{
            .params = &.{ null, null, null, null },
            .attributes = &.{ null_param, null_param, null_param, null_param },
            .expected = &[_]u8{0b11111111},
        },
        .{
            .params = &.{ null, null, null, null, null, null, null, null, null },
            .attributes = &.{ null_param, null_param },
            .expected = &[_]u8{ 0b11111111, 0b00000111 },
        },
    };

    inline for (tests) |t| {
        var buffer: [4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        _ = try writeNullBitmap(t.params, t.attributes, &fbs);

        const written = fbs.buffer[0..fbs.pos];
        try std.testing.expectEqualSlices(u8, t.expected, written);
    }
}
