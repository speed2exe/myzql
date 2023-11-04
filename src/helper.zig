/// This file is to store convenience functions and methods for callers.
const std = @import("std");
const constants = @import("./constants.zig");
const EnumFieldType = constants.EnumFieldType;
const result = @import("./result.zig");
const ResultSet = result.ResultSet;
const TextResultRow = result.TextResultRow;
const Options = result.BinaryResultRow.Options;
const protocol = @import("./protocol.zig");
const PacketReader = protocol.packet_reader.PacketReader;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;

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

// dest is a pointer to a struct
pub fn scanBinResRowtoStruct(dest: anytype, raw: []const u8, col_defs: []ColumnDefinition41) void {
    var reader = PacketReader.initFromPayload(raw);
    const first = reader.readByte();
    std.debug.assert(first == constants.BINARY_PROTOCOL_RESULTSET_ROW_HEADER);

    // null bitmap
    const null_bitmap_len = (col_defs.len + 7 + 2) / 8;
    const null_bitmap = reader.readFixedRuntime(null_bitmap_len);

    const child_type = @typeInfo(@TypeOf(dest)).Pointer.child;
    const struct_fields = @typeInfo(child_type).Struct.fields;

    std.debug.assert(struct_fields.len == col_defs.len);

    inline for (struct_fields, col_defs, 0..) |field, col_def, i| {
        if (!binResIsNull(null_bitmap, i)) {
            @field(dest, field.name) = binElemToValue(field.type, &col_def, &reader);
        } else {
            switch (@typeInfo(field.type)) {
                .Optional => @field(dest, field.name) = null,
                else => {
                    std.log.err("field {s} is not optional\n", .{field.name});
                    unreachable;
                },
            }
        }
    }
    std.debug.assert(reader.finished());
}

inline fn binElemToValue(comptime T: type, col_def: *const ColumnDefinition41, reader: *PacketReader) T {
    _ = reader;
    const col_type: EnumFieldType = @enumFromInt(col_def.column_type);
    return switch (col_type) {
        else => {
            std.log.err("unimplemented col_type: {any}\n", .{col_type});
            unreachable;
        },
        // .MYSQL_TYPE_DECIMAL => {},
        // .MYSQL_TYPE_TINY => {},
        // .MYSQL_TYPE_SHORT => {},
        // .MYSQL_TYPE_LONG => {},
        // .MYSQL_TYPE_FLOAT => {},
        // .MYSQL_TYPE_DOUBLE => {},
        // .MYSQL_TYPE_NULL => {},
        // .MYSQL_TYPE_TIMESTAMP => {},
        // .MYSQL_TYPE_LONGLONG => {},
        // .MYSQL_TYPE_INT24 => {},
        // .MYSQL_TYPE_DATE => {},
        // .MYSQL_TYPE_TIME => {},
        // .MYSQL_TYPE_DATETIME => {},
        // .MYSQL_TYPE_YEAR => {},
        // .MYSQL_TYPE_NEWDATE => {},
        // .MYSQL_TYPE_VARCHAR => {},
        // .MYSQL_TYPE_BIT => {},
        // .MYSQL_TYPE_TIMESTAMP2 => {},
        // .MYSQL_TYPE_DATETIME2 => {},
        // .MYSQL_TYPE_TIME2 => {},
        // .MYSQL_TYPE_TYPED_ARRAY => {},

        // .MYSQL_TYPE_INVALID => {},
        // .MYSQL_TYPE_BOOL => {},
        // .MYSQL_TYPE_JSON => {},
        // .MYSQL_TYPE_NEWDECIMAL => {},
        // .MYSQL_TYPE_ENUM => {},
        // .MYSQL_TYPE_SET => {},
        // .MYSQL_TYPE_TINY_BLOB => {},
        // .MYSQL_TYPE_MEDIUM_BLOB => {},
        // .MYSQL_TYPE_LONG_BLOB => {},
        // .MYSQL_TYPE_BLOB => {},
        // .MYSQL_TYPE_VAR_STRING => {},
        // .MYSQL_TYPE_STRING => {},
        // .MYSQL_TYPE_GEOMETRY => {},
    };
}

inline fn binResIsNull(null_bitmap: []const u8, col_idx: usize) bool {
    // TODO: optimize: divmod
    const byte_idx = (col_idx + 2) / 8;
    const bit_idx = (col_idx + 2) % 8;
    const byte = null_bitmap[byte_idx];
    return (byte & (1 << bit_idx)) > 0;
}

test "binResIsNull" {
    var tests = .{
        .{
            .null_bitmap = &.{0b00000100},
            .col_idx = 0,
            .expected = true,
        },
        .{
            .null_bitmap = &.{0b00000000},
            .col_idx = 0,
            .expected = false,
        },
        .{
            .null_bitmap = &.{ 0b00000000, 0b00000001 },
            .col_idx = 6,
            .expected = true,
        },
        .{
            .null_bitmap = &.{ 0b10000000, 0b00000000 },
            .col_idx = 5,
            .expected = true,
        },
    };

    inline for (tests) |t| {
        const actual = binResIsNull(t.null_bitmap, t.col_idx);
        try std.testing.expectEqual(t.expected, actual);
    }
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

            const num_cols = iter.text_result_set.col_defs.len;
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
