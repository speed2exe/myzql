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

pub fn ResultSetIter(comptime ResultRowType: type) type {
    return struct {
        text_result_set: *const ResultSet(ResultRowType),

        pub fn next(i: *const ResultSetIter(ResultRowType), allocator: std.mem.Allocator) !?ResultRowType {
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

        pub fn collect(iter: *const ResultSetIter(TextResultRow), allocator: std.mem.Allocator) !TableTexts {
            var row_acc = std.ArrayList(TextResultRow).init(allocator);
            while (try iter.next(allocator)) |row| {
                var new_row_ptr = try row_acc.addOne();
                new_row_ptr.* = row;
            }

            const num_cols = iter.text_result_set.column_definitions.len;
            var rows = try allocator.alloc([]?[]const u8, row_acc.items.len);
            var elems = try allocator.alloc(?[]const u8, row_acc.items.len * num_cols);
            for (row_acc.items, 0..) |row, i| {
                const dest_row = elems[i * num_cols .. (i + 1) * num_cols];
                try row.scan(dest_row);
                rows[i] = dest_row;
            }

            return .{
                .result_rows = try row_acc.toOwnedSlice(),
                .elems = elems,
                .rows = rows,
            };
        }
    };
}

pub const TableTexts = struct {
    result_rows: []TextResultRow,
    elems: []?[]const u8,
    rows: [][]?[]const u8,

    pub fn deinit(t: *const TableTexts, allocator: std.mem.Allocator) void {
        for (t.result_rows) |row| {
            row.deinit(allocator);
        }
        allocator.free(t.result_rows);
        allocator.free(t.rows);
        allocator.free(t.elems);
    }
};
