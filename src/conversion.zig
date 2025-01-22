const std = @import("std");
const PayloadReader = @import("./protocol/packet.zig").PayloadReader;
const ColumnDefinition41 = @import("./protocol/column_definition.zig").ColumnDefinition41;
const constants = @import("./constants.zig");
const DateTime = @import("./temporal.zig").DateTime;
const Duration = @import("./temporal.zig").Duration;
const EnumFieldType = @import("./constants.zig").EnumFieldType;
const Packet = @import("./protocol/packet.zig").Packet;

// dest is a pointer to a struct
pub fn scanBinResultRow(dest: anytype, packet: *const Packet, col_defs: []const ColumnDefinition41, allocator: ?std.mem.Allocator) !void {
    var reader = packet.reader();
    const first = reader.readByte();
    std.debug.assert(first == constants.BINARY_PROTOCOL_RESULTSET_ROW_HEADER);

    // null bitmap
    const null_bitmap_len = (col_defs.len + 7 + 2) / 8;
    const null_bitmap = reader.readRefRuntime(null_bitmap_len);

    const child_type = @typeInfo(@TypeOf(dest)).pointer.child;
    const struct_fields = @typeInfo(child_type).@"struct".fields;

    if (struct_fields.len != col_defs.len) {
        std.log.err("received {d} columns from mysql, but given {d} fields for struct", .{ struct_fields.len, col_defs.len });
        return error.ColumnAndFieldCountMismatch;
    }

    inline for (struct_fields, col_defs, 0..) |field, col_def, i| {
        const field_info = @typeInfo(field.type);
        const isNull = binResIsNull(null_bitmap, i);

        switch (field_info) {
            .optional => {
                if (isNull) {
                    @field(dest, field.name) = null;
                } else {
                    @field(dest, field.name) = try binElemToValue(field_info.optional.child, field.name, &col_def, &reader, allocator);
                }
            },
            else => {
                if (isNull) {
                    std.log.err("column: {s} value is null, but field: {s} is not nullable\n", .{ col_def.name, field.name });
                    return error.UnexpectedNullMySQLValue;
                }
                @field(dest, field.name) = try binElemToValue(field.type, field.name, &col_def, &reader, allocator);
            },
        }
    }
    std.debug.assert(reader.finished());
}

fn decodeDateTime(reader: *PayloadReader) DateTime {
    const length = reader.readByte();
    switch (length) {
        11 => return .{
            .year = reader.readInt(u16),
            .month = reader.readByte(),
            .day = reader.readByte(),
            .hour = reader.readByte(),
            .minute = reader.readByte(),
            .second = reader.readByte(),
            .microsecond = reader.readInt(u32),
        },
        7 => return .{
            .year = reader.readInt(u16),
            .month = reader.readByte(),
            .day = reader.readByte(),
            .hour = reader.readByte(),
            .minute = reader.readByte(),
            .second = reader.readByte(),
        },
        4 => return .{
            .year = reader.readInt(u16),
            .month = reader.readByte(),
            .day = reader.readByte(),
        },
        0 => return .{},
        else => unreachable,
    }
}

fn decodeDuration(reader: *PayloadReader) Duration {
    const length = reader.readByte();
    switch (length) {
        12 => return .{
            .is_negative = reader.readByte(),
            .days = reader.readInt(u32),
            .hours = reader.readByte(),
            .minutes = reader.readByte(),
            .seconds = reader.readByte(),
            .microseconds = reader.readInt(u32),
        },
        8 => return .{
            .is_negative = reader.readByte(),
            .days = reader.readInt(u32),
            .hours = reader.readByte(),
            .minutes = reader.readByte(),
            .seconds = reader.readByte(),
        },
        0 => return .{},
        else => {
            unreachable;
        },
    }
}

inline fn logConversionError(
    comptime FieldType: type,
    comptime field_name: []const u8,
    col_name: []const u8,
    col_type: EnumFieldType,
) void {
    std.log.err(
        "Conversion Error: MySQL Column: (name: {s}, type: {any}), Zig Value: (name: {s}, type: {any})\n",
        .{ col_name, col_type, field_name, FieldType },
    );
}

inline fn binElemToValue(
    comptime FieldType: type,
    comptime field_name: []const u8,
    col_def: *const ColumnDefinition41,
    reader: *PayloadReader,
    allocator: ?std.mem.Allocator,
) !FieldType {
    const field_info = @typeInfo(FieldType);
    const col_type: EnumFieldType = @enumFromInt(col_def.column_type);

    switch (FieldType) {
        DateTime => {
            switch (col_type) {
                .MYSQL_TYPE_DATE,
                .MYSQL_TYPE_DATETIME,
                .MYSQL_TYPE_TIMESTAMP,
                => return decodeDateTime(reader),
                else => {},
            }
        },
        Duration => {
            switch (col_type) {
                .MYSQL_TYPE_TIME => return decodeDuration(reader),
                else => {},
            }
        },
        else => {},
    }

    switch (field_info) {
        .pointer => |pointer| {
            switch (@typeInfo(pointer.child)) {
                .int => |int| {
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
                            => {
                                const str = reader.readLengthEncodedString();
                                if (allocator) |a| {
                                    if (pointer.sentinel()) |_| {
                                        return try a.dupeZ(u8, str);
                                    }
                                    return try a.dupe(u8, str);
                                }
                                return str;
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (std.mem.eql(u8, field.name, "buffer")) {
                    const info = @typeInfo(field.type);
                    switch (info) {
                        .array => |array| {
                            if (FieldType == std.BoundedArray(u8, array.len)) {
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
                                    => {
                                        const str = reader.readLengthEncodedString();
                                        var ret = try std.BoundedArray(u8, array.len).init(0);
                                        try ret.appendSlice(str[0..@min(str.len, array.len)]);
                                        return ret;
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
                break;
            }
        },

        .@"enum" => |e| {
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
                => {
                    const str = reader.readLengthEncodedString();
                    inline for (e.fields) |f| {
                        if (std.mem.eql(u8, str, f.name)) {
                            return @field(FieldType, f.name);
                        }
                    }
                    std.log.err(
                        "received string: {s} from mysql, but could not find tag from enum: {s}, field name: {s}\n",
                        .{ str, @typeName(FieldType), field_name },
                    );
                },
                else => {},
            }
        },
        .int => |int| {
            switch (int.signedness) {
                .unsigned => {
                    switch (col_type) {
                        .MYSQL_TYPE_LONGLONG => return @intCast(reader.readInt(u64)),

                        .MYSQL_TYPE_LONG,
                        .MYSQL_TYPE_INT24,
                        => return @intCast(reader.readInt(u32)),

                        .MYSQL_TYPE_SHORT,
                        .MYSQL_TYPE_YEAR,
                        => return @intCast(reader.readInt(u16)),

                        .MYSQL_TYPE_TINY => return @intCast(reader.readByte()),

                        else => {},
                    }
                },
                .signed => {
                    switch (col_type) {
                        .MYSQL_TYPE_LONGLONG => return @intCast(@as(i64, @bitCast(reader.readInt(u64)))),

                        .MYSQL_TYPE_LONG,
                        .MYSQL_TYPE_INT24,
                        => return @intCast(@as(i32, @bitCast(reader.readInt(u32)))),

                        .MYSQL_TYPE_SHORT,
                        .MYSQL_TYPE_YEAR,
                        => return @intCast(@as(i16, @bitCast(reader.readInt(u16)))),

                        .MYSQL_TYPE_TINY => return @intCast(@as(i8, @bitCast(reader.readByte()))),

                        else => {},
                    }
                },
            }
        },
        .float => |float| {
            if (float.bits >= 64) {
                switch (col_type) {
                    .MYSQL_TYPE_DOUBLE => return @as(f64, @bitCast(reader.readInt(u64))),
                    .MYSQL_TYPE_FLOAT => return @as(f32, @bitCast(reader.readInt(u32))),
                    else => {},
                }
            }
            if (float.bits >= 32) {
                switch (col_type) {
                    .MYSQL_TYPE_FLOAT => return @as(f32, @bitCast(reader.readInt(u32))),
                    else => {},
                }
            }
        },
        else => {},
    }

    logConversionError(FieldType, field_name, col_def.name, col_type);
    return error.IncompatibleBinaryConversion;
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
