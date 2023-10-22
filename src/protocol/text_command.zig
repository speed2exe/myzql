const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");
const packet_writer = @import("./packet_writer.zig");
const constants = @import("../constants.zig");

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const Query = struct {
    query: []const u8,

    params: []const ?[]const u8, //binary values
    param_types: []const [2]u8,
    param_names: []const []const u8,

    pub fn write(h: *const Query, writer: *stream_buffered.SmallPacketWriter, capabilities: u32) !void {
        try packet_writer.writeUInt8(writer, constants.COM_QUERY);

        if (capabilities & constants.CLIENT_QUERY_ATTRIBUTES > 0) {
            try packet_writer.writeLengthEncodedInteger(writer, h.params.len);
            try packet_writer.writeLengthEncodedInteger(writer, 1); // Number of parameter sets. Currently always 1
            if (h.params.len > 0) {
                writeNullBitmap(h.params, writer);
                const new_param_bind_flag = true; // Always 1. Malformed packet error if not 1
                if (new_param_bind_flag) {
                    for (h.params, 0..) |_, i| {
                        try writer.write(&h.param_types[i]);
                        try writer.write(&h.param_names[i]);
                    }
                    // TODO: write binary different for types
                }
            }
        }
    }
};

fn writeNullBitmap(params: []const ?[]const u8, writer: anytype) !void {
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
    var params: []const ?[]const u8 = &.{ null, "some-data", null };

    var buffer: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    _ = try writeNullBitmap(params, &fbs);

    const written = fbs.buffer[0..fbs.pos];

    // TODO: not sure if this is the expected result
    // but it serves a good reference for now
    // could be big endian
    try std.testing.expectEqualSlices(u8, written, &[_]u8{0b00000101});
}
