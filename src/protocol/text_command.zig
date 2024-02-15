const std = @import("std");
const PacketWriter = @import("./packet_writer.zig").PacketWriter;
const constants = @import("../constants.zig");

pub const QueryParam = struct {
    type_and_flag: [2]u8, // LSB: type, MSB: flag
    name: []const u8,
    value: []const u8,
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const QueryRequest = struct {
    query: []const u8,

    // params
    capabilities: u32 = 0,
    params: []const ?QueryParam = &.{},

    pub fn write(q: *const QueryRequest, writer: *PacketWriter) !void {
        // Packet Header
        try writer.writeUInt8(constants.COM_QUERY);

        // Query Parameters
        if (q.capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) {
            try writer.writeLengthEncodedInteger(q.params.len);
            try writer.writeLengthEncodedInteger(1); // Number of parameter sets. Currently always 1
            if (q.params.len > 0) {
                // NULL bitmap, length= (num_params + 7) / 8
                try writeNullBitmap(q.params);

                // new_params_bind_flag
                // Always 1. Malformed packet error if not 1
                try writer.writeUInt8(1);

                // write type_and_flag, name and values
                // for each parameter
                for (q.params) |p_opt| {
                    const p = p_opt orelse continue; // TODO: may not be correct
                    try writer.write(&p.type_and_flag);
                    try writer.writeLengthEncodedString(p.name);
                    try writer.write(p.value);
                }
            }
        }

        // Query String
        try writer.write(q.query);
    }
};

pub fn writeNullBitmap(params: []const ?QueryParam, writer: PacketWriter) !void {
    const byte_count = (params.len + 7) / 8;
    for (0..byte_count) |i| {
        const byte = nullBits(params[i * 8 ..]);
        try writer.writeInt(u8, byte);
    }
}

pub fn nullBits(params: []const ?QueryParam) u8 {
    const final_params = if (params.len > 8)
        params[0..8]
    else
        params;

    var byte: u8 = 0;
    var current_bit: u8 = 1;
    for (final_params) |p_opt| {
        if (p_opt == null) {
            byte |= current_bit;
        }
        current_bit <<= 1;
    }
    return byte;
}

test "writeNullBitmap - 1" {
    const params: []const ?QueryParam = &.{
        null,
        .{
            .type_and_flag = .{ 0, 0 },
            .name = "foo",
            .value = "bar",
        },
        null,
    };

    var buffer: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try writeNullBitmap(params, &fbs);

    const written = fbs.buffer[0..fbs.pos];

    // TODO: not sure if this is the expected result
    // but it serves a good reference for now
    // could be big endian
    try std.testing.expectEqualSlices(u8, written, &[_]u8{0b00000101});
}

test "writeNullBitmap - 2" {
    const params: []const ?QueryParam = &.{
        null, null, null, null,
        null, null, null, null,
        null, null, null, null,
    };

    var buffer: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try writeNullBitmap(params, &fbs);

    const written = fbs.buffer[0..fbs.pos];

    // TODO: not sure if this is the expected result
    // but it serves a good reference for now
    // could be big endian
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0b11111111, 0b00001111 }, written);
}
