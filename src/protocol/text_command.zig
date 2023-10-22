const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const constants = @import("../constants.zig");

pub const QueryParam = struct {
    type_and_flag: [2]u8, // MSB: flag, LSB: type
    name: []const u8,
    value: []const u8,
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const QueryRequest = struct {
    query: []const u8,

    // params
    capabilities: u32 = 0,
    params: []const ?QueryParam = &.{},

    pub fn write(q: *const QueryRequest, writer: *stream_buffered.SmallPacketWriter) !void {
        // Packet Header
        try packet_writer.writeUInt8(writer, constants.COM_QUERY);

        // Query Parameters
        if (q.capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) {
            try packet_writer.writeLengthEncodedInteger(writer, q.params.len);
            try packet_writer.writeLengthEncodedInteger(writer, 1); // Number of parameter sets. Currently always 1
            if (q.params.len > 0) {
                // NULL bitmap, length= (num_params + 7) / 8
                try writeNullBitmap(q.params, writer);

                // new_params_bind_flag
                // Always 1. Malformed packet error if not 1
                try packet_writer.writeUInt8(writer, 1);

                // write type_and_flag, name and values
                // for each parameter
                for (q.params) |p_opt| {
                    const p = p_opt orelse continue; // TODO: may not be correct
                    try writer.write(&p.type_and_flag);
                    try packet_writer.writeLengthEncodedString(writer, p.name);
                    try writer.write(p.value);
                }
            }
        }

        // Query String
        try writer.write(q.query);
    }
};

fn writeNullBitmap(params: []const ?QueryParam, writer: anytype) !void {
    const byte_count = (params.len + 7) / 8;
    var cur_param_index: usize = 0;

    for (0..byte_count) |_| {
        var byte: u8 = 0; // byte that is going to be send
        var current_bit: u8 = 1;
        while (cur_param_index < params.len) {
            if (params[cur_param_index] == null) {
                byte |= current_bit;
            }
            current_bit <<= 1;
            cur_param_index += 1;
        }

        try packet_writer.writeUInt8(writer, byte);
    }
}

test "writeNullBitmap - 1" {
    var params: []const ?QueryParam = &.{
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
    _ = try writeNullBitmap(params, &fbs);

    const written = fbs.buffer[0..fbs.pos];

    // TODO: not sure if this is the expected result
    // but it serves a good reference for now
    // could be big endian
    try std.testing.expectEqualSlices(u8, written, &[_]u8{0b00000101});
}
