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
const packet_writer = protocol.packet_writer;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;
const DateTime = @import("./temporal.zig").DateTime;

fn comptimeIntToUInt(
    comptime Unsigned: type,
    comptime Signed: type,
    comptime int: comptime_int,
) Unsigned {
    return blk: {
        if (comptime (int < 0)) {
            break :blk @bitCast(@as(Signed, int));
        } else {
            break :blk int;
        }
    };
}

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html#sect_protocol_binary_resultset_row_value
// https://mariadb.com/kb/en/com_stmt_execute/#binary-parameter-encoding
pub fn encodeBinaryParam(param: anytype, col_def: *const ColumnDefinition41, writer: anytype) !void {
    const param_type_info = @typeInfo(@TypeOf(param));
    const col_type: EnumFieldType = @enumFromInt(col_def.column_type);

    switch (param_type_info) {
        .Struct => {
            switch (col_type) {
                .MYSQL_TYPE_DATETIME => {
                    return try encodeDateTime(param, writer);
                },
                else => {},
            }
        },
        .Null => return,
        .Optional => {
            if (param) |p| {
                return encodeBinaryParam(p, col_def, writer);
            } else {
                return;
            }
        },
        .Int => |int| {
            const UnsignedInt: type = comptime blk: {
                var int_type_info = @typeInfo(@TypeOf(param));
                int_type_info.Int.signedness = .unsigned;
                break :blk @Type(int_type_info);
            };

            switch (col_type) {
                .MYSQL_TYPE_LONGLONG => {
                    if (int.bits <= 64) {
                        return try packet_writer.writeUInt64(writer, @as(UnsignedInt, @bitCast(param)));
                    }
                },
                .MYSQL_TYPE_LONG,
                .MYSQL_TYPE_INT24,
                => {
                    if (int.bits <= 32) {
                        return try packet_writer.writeUInt32(writer, @as(UnsignedInt, @bitCast(param)));
                    }
                },
                .MYSQL_TYPE_SHORT,
                .MYSQL_TYPE_YEAR,
                => {
                    if (int.bits <= 16) {
                        return try packet_writer.writeUInt16(writer, @as(UnsignedInt, @bitCast(param)));
                    }
                },
                .MYSQL_TYPE_TINY => {
                    if (int.bits <= 8) {
                        return try packet_writer.writeUInt8(writer, @as(UnsignedInt, @bitCast(param)));
                    }
                },
                else => {},
            }
        },
        .ComptimeInt => {
            switch (col_type) {
                .MYSQL_TYPE_LONGLONG => {
                    if (param <= std.math.maxInt(u64) and param >= std.math.minInt(i64)) {
                        const value: u64 = comptimeIntToUInt(u64, i64, param);
                        return try packet_writer.writeUInt64(writer, value);
                    }
                },
                .MYSQL_TYPE_LONG,
                .MYSQL_TYPE_INT24,
                => {
                    if (param <= std.math.maxInt(u32) and param >= std.math.minInt(i32)) {
                        const value: u32 = comptimeIntToUInt(u32, i32, param);
                        return try packet_writer.writeUInt32(writer, value);
                    }
                },
                .MYSQL_TYPE_SHORT,
                .MYSQL_TYPE_YEAR,
                => {
                    if (param <= std.math.maxInt(u16) and param >= std.math.minInt(i16)) {
                        const value: u16 = comptimeIntToUInt(u16, i16, param);
                        return try packet_writer.writeUInt16(writer, value);
                    }
                },
                .MYSQL_TYPE_TINY => {
                    if (param <= std.math.maxInt(u8) and param >= std.math.minInt(i8)) {
                        const value: u8 = comptimeIntToUInt(u8, i8, param);
                        return try packet_writer.writeUInt8(writer, value);
                    }
                },
                else => {},
            }
        },
        .Float => |float| {
            switch (col_type) {
                .MYSQL_TYPE_DOUBLE => {
                    if (float.bits <= 64) {
                        return try packet_writer.writeUInt64(writer, @bitCast(@as(f64, param)));
                    }
                },
                .MYSQL_TYPE_FLOAT => {
                    if (float.bits <= 32) {
                        return try packet_writer.writeUInt32(writer, @bitCast(@as(f32, param)));
                    }
                },
                else => {},
            }
        },
        .ComptimeFloat => {
            switch (col_type) {
                .MYSQL_TYPE_DOUBLE => {
                    return try packet_writer.writeUInt64(writer, @bitCast(@as(f64, param)));
                },
                .MYSQL_TYPE_FLOAT => {
                    return try packet_writer.writeUInt32(writer, @bitCast(@as(f32, param)));
                },
                else => {},
            }
        },
        .Array => |array| {
            switch (@typeInfo(array.child)) {
                .Int => |int| {
                    if (int.bits == 8) {
                        switch (col_type) {
                            .MYSQL_TYPE_STRING,
                            .MYSQL_TYPE_VARCHAR,
                            .MYSQL_TYPE_VAR_STRING,
                            .MYSQL_TYPE_ENUM,
                            .MYSQL_TYPE_SET,
                            .MYSQL_TYPE_LONG_BLOB,
                            .MYSQL_TYPE_MEDIUM_BLOB,
                            .MYSQL_TYPE_BLOB,
                            .MYSQL_TYPE_TINY_BLOB,
                            .MYSQL_TYPE_GEOMETRY,
                            .MYSQL_TYPE_BIT,
                            .MYSQL_TYPE_DECIMAL,
                            .MYSQL_TYPE_NEWDECIMAL,
                            => return try packet_writer.writeLengthEncodedString(writer, &param),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        },
        .Pointer => |pointer| {
            switch (pointer.size) {
                .One => return encodeBinaryParam(param.*, col_def, writer),
                else => {},
            }
            switch (@typeInfo(pointer.child)) {
                .Int => |int| {
                    if (int.bits == 8) {
                        switch (col_type) {
                            .MYSQL_TYPE_STRING,
                            .MYSQL_TYPE_VARCHAR,
                            .MYSQL_TYPE_VAR_STRING,
                            .MYSQL_TYPE_ENUM,
                            .MYSQL_TYPE_SET,
                            .MYSQL_TYPE_LONG_BLOB,
                            .MYSQL_TYPE_MEDIUM_BLOB,
                            .MYSQL_TYPE_BLOB,
                            .MYSQL_TYPE_TINY_BLOB,
                            .MYSQL_TYPE_GEOMETRY,
                            .MYSQL_TYPE_BIT,
                            .MYSQL_TYPE_DECIMAL,
                            .MYSQL_TYPE_NEWDECIMAL,
                            => switch (pointer.size) {
                                .C, .Many => return try packet_writer.writeLengthEncodedString(writer, std.mem.span(param)),
                                .Slice => return try packet_writer.writeLengthEncodedString(writer, param),
                                else => {},
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    // comptime FieldType: type, field_name: []const u8, col_name: []const u8, col_type: EnumFieldType)
    // TODO: insert field name if struct is passed in
    logConversionError(@TypeOf(param), "", col_def.name, col_type);
    return error.InvalidConversion;
}

// To save space the packet can be compressed:
// if year, month, day, hour, minutes, seconds and microseconds are all 0, length is 0 and no other field is sent.
// if hour, seconds and microseconds are all 0, length is 4 and no other field is sent.
// if microseconds is 0, length is 7 and micro_seconds is not sent.
// otherwise the length is 11
fn encodeDateTime(dt: DateTime, writer: anytype) !void {
    if (dt.microsecond > 0) {
        try packet_writer.writeUInt8(writer, 11);
        try packet_writer.writeUInt16(writer, dt.year);
        try packet_writer.writeUInt8(writer, dt.month);
        try packet_writer.writeUInt8(writer, dt.day);
        try packet_writer.writeUInt8(writer, dt.hour);
        try packet_writer.writeUInt8(writer, dt.minute);
        try packet_writer.writeUInt8(writer, dt.second);
        try packet_writer.writeUInt32(writer, dt.microsecond);
    } else if (dt.hour > 0 or dt.minute > 0 or dt.second > 0) {
        try packet_writer.writeUInt8(writer, 7);
        try packet_writer.writeUInt16(writer, dt.year);
        try packet_writer.writeUInt8(writer, dt.month);
        try packet_writer.writeUInt8(writer, dt.day);
        try packet_writer.writeUInt8(writer, dt.hour);
        try packet_writer.writeUInt8(writer, dt.minute);
        try packet_writer.writeUInt8(writer, dt.second);
    } else if (dt.year > 0 or dt.month > 0 or dt.day > 0) {
        try packet_writer.writeUInt8(writer, 4);
        try packet_writer.writeUInt16(writer, dt.year);
        try packet_writer.writeUInt8(writer, dt.month);
        try packet_writer.writeUInt8(writer, dt.day);
    } else {
        try packet_writer.writeUInt8(writer, 0);
    }
}

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
        const field_info = @typeInfo(field.type);
        const isNull = binResIsNull(null_bitmap, i);

        switch (field_info) {
            .Optional => {
                if (isNull) {
                    @field(dest, field.name) = null;
                } else {
                    @field(dest, field.name) = binElemToValue(field_info.Optional.child, field.name, &col_def, &reader);
                }
            },
            else => {
                if (isNull) {
                    std.log.err("column: {s} value is null, but field: {s} is not nullable\n", .{ col_def.name, field.name });
                    unreachable;
                }
                @field(dest, field.name) = binElemToValue(field.type, field.name, &col_def, &reader);
            },
        }
    }
    std.debug.assert(reader.finished());
}

inline fn logConversionError(comptime FieldType: type, field_name: []const u8, col_name: []const u8, col_type: EnumFieldType) void {
    std.log.err(
        "MySQL Column: (name: {s}, type: {any}), Zig Value: (name: {s}, type: {any})\n",
        .{ col_name, col_type, field_name, FieldType },
    );
}

inline fn binElemToValue(comptime FieldType: type, field_name: []const u8, col_def: *const ColumnDefinition41, reader: *PacketReader) FieldType {
    const field_info = @typeInfo(FieldType);
    const col_type: EnumFieldType = @enumFromInt(col_def.column_type);

    switch (field_info) {
        .Pointer => |pointer| {
            switch (@typeInfo(pointer.child)) {
                .Int => |int| {
                    if (int.bits == 8) {
                        switch (col_type) {
                            .MYSQL_TYPE_STRING,
                            .MYSQL_TYPE_VARCHAR,
                            .MYSQL_TYPE_VAR_STRING,
                            .MYSQL_TYPE_ENUM,
                            .MYSQL_TYPE_SET,
                            .MYSQL_TYPE_LONG_BLOB,
                            .MYSQL_TYPE_MEDIUM_BLOB,
                            .MYSQL_TYPE_BLOB,
                            .MYSQL_TYPE_TINY_BLOB,
                            .MYSQL_TYPE_GEOMETRY,
                            .MYSQL_TYPE_BIT,
                            .MYSQL_TYPE_DECIMAL,
                            .MYSQL_TYPE_NEWDECIMAL,
                            => return reader.readLengthEncodedString(),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        },
        .Int => switch (col_type) {
            .MYSQL_TYPE_LONGLONG => return @intCast(reader.readUInt64()),

            .MYSQL_TYPE_LONG,
            .MYSQL_TYPE_INT24,
            => return @intCast(reader.readUInt32()),

            .MYSQL_TYPE_SHORT,
            .MYSQL_TYPE_YEAR,
            => return @intCast(reader.readUInt16()),

            .MYSQL_TYPE_TINY => return @intCast(reader.readUInt16()),

            else => {},
        },
        else => {},
    }

    logConversionError(FieldType, field_name, col_def.name, col_type);
    unreachable;
}

inline fn binResIsNull(null_bitmap: []const u8, col_idx: usize) bool {
    // TODO: optimize: divmod
    const byte_idx = (col_idx + 2) / 8;
    const bit_idx = (col_idx + 2) % 8;
    const byte = null_bitmap[byte_idx];
    return (byte & (1 << bit_idx)) > 0;
}

test "binResIsNull" {
    const tests = .{
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
                const new_row_ptr = try row_acc.addOne();
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
