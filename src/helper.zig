/// This file is to store convenience functions and methods for callers.
const std = @import("std");
const constants = @import("./constants.zig");
const result = @import("./result.zig");
const ResultSet = result.ResultSet;
const TextResultRow = result.TextResultRow;
const Options = result.BinaryResultRow.Options;
const PacketReader = @import("./protocol/packet_reader.zig").PacketReader;

pub fn scanTextResultRow(raw: []const u8, dest: []?[]const u8) !void {
    var packet_reader = PacketReader.initFromPayload(raw);
    for (dest) |*d| {
        d.* = blk: {
            const first_byte = blk2: {
                const byte_opt = packet_reader.peek();
                break :blk2 byte_opt orelse return error.NoNextByte;
            };
            if (first_byte == constants.TEXT_RESULT_ROW_NULL) {
                packet_reader.forward_one();
                break :blk null;
            }
            break :blk packet_reader.readLengthEncodedString();
        };
    }
}

pub fn scanBinaryResultRow(comptime T: type, raw: []const u8, dest: *T, options: Options) !void {
    _ = options;
    _ = dest;
    _ = raw;
    @panic("not implemented");
}

pub const TextResultSetIter = struct {
    text_result_set: *const ResultSet(TextResultRow),

    pub fn next(i: *const TextResultSetIter, allocator: std.mem.Allocator) !?TextResultRow {
        const row = try i.text_result_set.readRow(allocator);
        return switch (row.value) {
            .eof => {
                // need to deinit as caller would not know to do so
                row.deinit(allocator);
                return null;
            },
            .err => |err| err.asError(),
            else => row,
        };
    }
};
