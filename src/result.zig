const std = @import("std");
const protocol = @import("./protocol.zig");
const constants = @import("./constants.zig");
const prep_stmts = protocol.prepared_statements;
const PrepareOk = prep_stmts.PrepareOk;
const Packet = protocol.packet.Packet;
const OkPacket = protocol.generic_response.OkPacket;
const ErrorPacket = protocol.generic_response.ErrorPacket;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;
const Conn = @import("./conn.zig").Conn;
const EofPacket = protocol.generic_response.EofPacket;
const PacketReader = @import("./protocol/packet_reader.zig").PacketReader;
const DateTime = @import("./temporal.zig").DateTime;
const Duration = @import("./temporal.zig").Duration;
const EnumFieldType = constants.EnumFieldType;

pub fn QueryResult(comptime T: type) type {
    return struct {
        const Value = union(enum) {
            ok: OkPacket,
            err: ErrorPacket,
            rows: ResultSet(T),
        };
        packet: Packet,
        value: Value,

        pub fn init(conn: *Conn, allocator: std.mem.Allocator) !QueryResult(T) {
            const response_packet = try conn.readPacket(allocator);
            return .{
                .packet = response_packet,
                .value = switch (response_packet.payload[0]) {
                    constants.OK => .{ .ok = OkPacket.initFromPacket(&response_packet, conn.client_capabilities) },
                    constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &response_packet) },
                    constants.LOCAL_INFILE_REQUEST => _ = @panic("not implemented"),
                    else => .{ .rows = blk: {
                        var packet_reader = PacketReader.initFromPacket(&response_packet);
                        const column_count = packet_reader.readLengthEncodedInteger();
                        std.debug.assert(packet_reader.finished());
                        break :blk try ResultSet(T).init(allocator, conn, column_count);
                    } },
                },
            };
        }

        pub fn deinit(q: *const QueryResult(T), allocator: std.mem.Allocator) void {
            q.packet.deinit(allocator);
            switch (q.value) {
                .rows => |rows| rows.deinit(allocator),
                else => {},
            }
        }

        pub fn expect(
            q: *const QueryResult(T),
            comptime value_variant: std.meta.FieldEnum(Value),
        ) !std.meta.FieldType(Value, value_variant) {
            return switch (q.value) {
                value_variant => @field(q.value, @tagName(value_variant)),
                else => {
                    return switch (q.value) {
                        .err => |err| return err.asError(),
                        .ok => |ok| {
                            std.log.err("Unexpected OkPacket: {any}\n", .{ok});
                            return error.UnexpectedOk;
                        },
                        .rows => |rows| {
                            std.log.err("Unexpected ResultSet: {any}\n", .{rows});
                            return error.UnexpectedResultSet;
                        },
                    };
                },
            };
        }
    };
}

pub fn ResultSet(comptime T: type) type {
    return struct {
        conn: *Conn,
        col_packets: []const Packet,
        col_defs: []const ColumnDefinition41,

        pub fn init(allocator: std.mem.Allocator, conn: *Conn, column_count: u64) !ResultSet(T) {
            const col_packets = try allocator.alloc(Packet, column_count);
            errdefer allocator.free(col_packets);

            const col_defs = try allocator.alloc(ColumnDefinition41, column_count);
            errdefer allocator.free(col_defs);

            for (col_packets, col_defs) |*pac, *def| {
                pac.* = try conn.readPacket(allocator);
                def.* = ColumnDefinition41.initFromPacket(pac);
            }

            // const packet = try conn.readPacket(allocator);
            // defer packet.deinit(allocator);
            // switch (packet.payload[0]) {
            //     constants.EOF, constants.OK => _ = OkPacket.initFromPacket(&packet, conn.client_capabilities),
            //     else => return packet.asError(conn.client_capabilities),
            // }

            return .{
                .conn = conn,
                .col_packets = col_packets,
                .col_defs = col_defs,
            };
        }

        fn deinit(t: *const ResultSet(T), allocator: std.mem.Allocator) void {
            for (t.col_packets) |packet| {
                packet.deinit(allocator);
            }
            allocator.free(t.col_packets);
            allocator.free(t.col_defs);
        }

        pub fn readRow(t: *const ResultSet(T), allocator: std.mem.Allocator) !ResultRow(T) {
            return ResultRow(T).init(t.conn, allocator, t.col_defs);
        }

        pub fn iter(t: *const ResultSet(T)) ResultSetIter(T) {
            return .{ .result_set = t };
        }
    };
}

pub const TextResultData = struct {
    raw: []const u8,
    col_defs: []const ColumnDefinition41,

    pub fn scan(t: *const TextResultData, dest: []?[]const u8) !void {
        std.debug.assert(dest.len == t.col_defs.len);
        try scanTextResultRow(dest, t.raw);
    }

    pub fn scanAlloc(t: *const TextResultData, allocator: std.mem.Allocator) ![]?[]const u8 {
        const record = try allocator.alloc(?[]const u8, t.col_defs.len);
        try t.scan(record);
        return record;
    }
};

pub const BinaryResultData = struct {
    raw: []const u8,
    col_defs: []const ColumnDefinition41,

    // dest: pointer to a struct
    pub fn scan(b: *const BinaryResultData, dest: anytype) !void {
        try scanBinResultRow(dest, b.raw, b.col_defs);
    }

    // returns a pointer to allocated struct object, caller must remember to call destroy on the object after use
    pub fn scanAlloc(b: *const BinaryResultData, comptime S: type, allocator: std.mem.Allocator) !*S {
        const s = try allocator.create(S);
        try b.scan(s);
        return s;
    }
};

pub fn ResultRow(comptime T: type) type {
    return struct {
        const Value = union(enum) {
            err: ErrorPacket,
            ok: OkPacket,
            data: T,
        };
        packet: Packet,
        value: Value,

        fn init(conn: *Conn, allocator: std.mem.Allocator, col_defs: []const ColumnDefinition41) !ResultRow(T) {
            const packet = try conn.readPacket(allocator);
            return .{
                .packet = packet,
                .value = switch (packet.payload[0]) {
                    constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &packet) },
                    constants.EOF => .{ .ok = OkPacket.initFromPacket(&packet, conn.client_capabilities) },
                    else => .{ .data = .{ .raw = packet.payload, .col_defs = col_defs } },
                },
            };
        }

        pub fn expect(
            r: *const ResultRow(T),
            comptime variant: std.meta.FieldEnum(Value),
        ) !std.meta.FieldType(Value, variant) {
            return switch (r.value) {
                variant => @field(r.value, @tagName(variant)),
                else => {
                    return switch (r.value) {
                        .err => |err| return err.asError(),
                        .ok => |_| return r.packet.asError(),
                        .data => |data| {
                            std.log.err("Unexpected ResultData: {any}\n", .{data});
                            return error.UnexpectedResultData;
                        },
                    };
                },
            };
        }

        pub fn deinit(r: *const ResultRow(T), allocator: std.mem.Allocator) void {
            r.packet.deinit(allocator);
        }
    };
}

pub const PrepareResult = struct {
    const Value = union(enum) {
        err: ErrorPacket,
        ok: PreparedStatement,
    };

    packet: Packet,
    value: Value,

    pub fn init(conn: *Conn, allocator: std.mem.Allocator) !PrepareResult {
        const response_packet = try conn.readPacket(allocator);
        return .{
            .packet = response_packet,
            .value = switch (response_packet.payload[0]) {
                constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &response_packet) },
                constants.OK => .{ .ok = try PreparedStatement.initFromPacket(&response_packet, conn, allocator) },
                else => return response_packet.asError(),
            },
        };
    }

    pub fn deinit(p: *const PrepareResult, allocator: std.mem.Allocator) void {
        p.packet.deinit(allocator);
        switch (p.value) {
            .ok => |prep_stmt| prep_stmt.deinit(allocator),
            else => {},
        }
    }

    pub fn expect(
        p: *const PrepareResult,
        comptime value_variant: std.meta.FieldEnum(Value),
    ) !std.meta.FieldType(Value, value_variant) {
        return switch (p.value) {
            value_variant => @field(p.value, @tagName(value_variant)),
            else => {
                return switch (p.value) {
                    .err => |err| return err.asError(),
                    .ok => |ok| {
                        std.log.err("Unexpected OkPacket: {any}\n", .{ok});
                        return error.UnexpectedOk;
                    },
                };
            },
        };
    }
};

pub const PreparedStatement = struct {
    prep_ok: PrepareOk,
    packets: []const Packet,
    col_defs: []const ColumnDefinition41,
    params: []const ColumnDefinition41, // parameters that would be passed when executing the query
    res_cols: []const ColumnDefinition41, // columns that would be returned when executing the query

    pub fn initFromPacket(resp_packet: *const Packet, conn: *Conn, allocator: std.mem.Allocator) !PreparedStatement {
        const prep_ok = PrepareOk.initFromPacket(resp_packet, conn.client_capabilities);

        const col_count = prep_ok.num_params + prep_ok.num_columns;

        const packets = try allocator.alloc(Packet, col_count);
        errdefer allocator.free(packets);

        const col_defs = try allocator.alloc(ColumnDefinition41, col_count);
        errdefer allocator.free(col_defs);

        for (packets, col_defs) |*packet, *col_def| {
            packet.* = try conn.readPacket(allocator);
            col_def.* = ColumnDefinition41.initFromPacket(packet);
        }

        return .{
            .prep_ok = prep_ok,
            .packets = packets,
            .col_defs = col_defs,
            .params = col_defs[0..prep_ok.num_params],
            .res_cols = col_defs[prep_ok.num_params..],
        };
    }

    pub fn deinit(prep_stmt: *const PreparedStatement, allocator: std.mem.Allocator) void {
        allocator.free(prep_stmt.col_defs);
        for (prep_stmt.packets) |packet| {
            packet.deinit(allocator);
        }
        allocator.free(prep_stmt.packets);
    }
};

// dest is a pointer to a struct
fn scanBinResultRow(dest: anytype, raw: []const u8, col_defs: []const ColumnDefinition41) !void {
    var reader = PacketReader.initFromPayload(raw);
    const first = reader.readByte();
    std.debug.assert(first == constants.BINARY_PROTOCOL_RESULTSET_ROW_HEADER);

    // null bitmap
    const null_bitmap_len = (col_defs.len + 7 + 2) / 8;
    const null_bitmap = reader.readFixedRuntime(null_bitmap_len);

    const child_type = @typeInfo(@TypeOf(dest)).Pointer.child;
    const struct_fields = @typeInfo(child_type).Struct.fields;

    if (struct_fields.len != col_defs.len) {
        std.log.err("received {d} columns from mysql, but given {d} fields for struct", .{ struct_fields.len, col_defs.len });
        return error.ColumnAndFieldCountMismatch;
    }

    inline for (struct_fields, col_defs, 0..) |field, col_def, i| {
        const field_info = @typeInfo(field.type);
        const isNull = binResIsNull(null_bitmap, i);

        switch (field_info) {
            .Optional => {
                if (isNull) {
                    @field(dest, field.name) = null;
                } else {
                    @field(dest, field.name) = try binElemToValue(field_info.Optional.child, field.name, &col_def, &reader);
                }
            },
            else => {
                if (isNull) {
                    std.log.err("column: {s} value is null, but field: {s} is not nullable\n", .{ col_def.name, field.name });
                    return error.UnexpectedNullMySQLValue;
                }
                @field(dest, field.name) = try binElemToValue(field.type, field.name, &col_def, &reader);
            },
        }
    }
    std.debug.assert(reader.finished());
}

fn decodeDateTime(reader: *PacketReader) DateTime {
    const length = reader.readByte();
    switch (length) {
        11 => return .{
            .year = reader.readUInt16(),
            .month = reader.readByte(),
            .day = reader.readByte(),
            .hour = reader.readByte(),
            .minute = reader.readByte(),
            .second = reader.readByte(),
            .microsecond = reader.readUInt32(),
        },
        7 => return .{
            .year = reader.readUInt16(),
            .month = reader.readByte(),
            .day = reader.readByte(),
            .hour = reader.readByte(),
            .minute = reader.readByte(),
            .second = reader.readByte(),
        },
        4 => return .{
            .year = reader.readUInt16(),
            .month = reader.readByte(),
            .day = reader.readByte(),
        },
        0 => return .{},
        else => unreachable,
    }
}

fn decodeDuration(reader: *PacketReader) Duration {
    const length = reader.readByte();
    switch (length) {
        12 => return .{
            .is_negative = reader.readByte(),
            .days = reader.readUInt32(),
            .hours = reader.readByte(),
            .minutes = reader.readByte(),
            .seconds = reader.readByte(),
            .microseconds = reader.readUInt32(),
        },
        8 => return .{
            .is_negative = reader.readByte(),
            .days = reader.readUInt32(),
            .hours = reader.readByte(),
            .minutes = reader.readByte(),
            .seconds = reader.readByte(),
        },
        0 => return .{},
        else => {
            std.debug.print("length: {d}\n", .{length});
            unreachable;
        },
    }
}

pub fn scanTextResultRow(dest: []?[]const u8, raw: []const u8) !void {
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

inline fn logConversionError(comptime FieldType: type, field_name: []const u8, col_name: []const u8, col_type: EnumFieldType) void {
    std.log.err(
        "Conversion Error: MySQL Column: (name: {s}, type: {any}), Zig Value: (name: {s}, type: {any})\n",
        .{ col_name, col_type, field_name, FieldType },
    );
}

inline fn binElemToValue(comptime FieldType: type, field_name: []const u8, col_def: *const ColumnDefinition41, reader: *PacketReader) !FieldType {
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
        .Enum => |e| {
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
        .Int => |int| {
            switch (int.signedness) {
                .unsigned => {
                    switch (col_type) {
                        .MYSQL_TYPE_LONGLONG => return @intCast(reader.readUInt64()),

                        .MYSQL_TYPE_LONG,
                        .MYSQL_TYPE_INT24,
                        => return @intCast(reader.readUInt32()),

                        .MYSQL_TYPE_SHORT,
                        .MYSQL_TYPE_YEAR,
                        => return @intCast(reader.readUInt16()),

                        .MYSQL_TYPE_TINY => return @intCast(reader.readByte()),

                        else => {},
                    }
                },
                .signed => {
                    switch (col_type) {
                        .MYSQL_TYPE_LONGLONG => return @intCast(@as(i64, @bitCast(reader.readUInt64()))),

                        .MYSQL_TYPE_LONG,
                        .MYSQL_TYPE_INT24,
                        => return @intCast(@as(i32, @bitCast(reader.readUInt32()))),

                        .MYSQL_TYPE_SHORT,
                        .MYSQL_TYPE_YEAR,
                        => return @intCast(@as(i16, @bitCast(reader.readUInt16()))),

                        .MYSQL_TYPE_TINY => return @intCast(@as(i8, @bitCast(reader.readByte()))),

                        else => {},
                    }
                },
            }
        },
        .Float => |float| {
            if (float.bits >= 64) {
                switch (col_type) {
                    .MYSQL_TYPE_DOUBLE => return @as(f64, @bitCast(reader.readUInt64())),
                    .MYSQL_TYPE_FLOAT => return @as(f32, @bitCast(reader.readUInt32())),
                    else => {},
                }
            }
            if (float.bits >= 32) {
                switch (col_type) {
                    .MYSQL_TYPE_FLOAT => return @as(f32, @bitCast(reader.readUInt32())),
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

pub fn ResultSetIter(comptime T: type) type {
    return struct {
        result_set: *const ResultSet(T),

        pub fn next(iter: *const ResultSetIter(T), allocator: std.mem.Allocator) !?ResultRow(T) {
            const row = try iter.result_set.readRow(allocator);
            return switch (row.value) {
                .ok => {
                    // need to deinit as caller would not know to do so
                    row.deinit(allocator);
                    return null;
                },
                .err => |err| err.asError(),
                else => row,
            };
        }

        pub fn collectTexts(iter: *const ResultSetIter(TextResultData), allocator: std.mem.Allocator) !TableTexts {
            var row_acc = std.ArrayList(ResultRow(TextResultData)).init(allocator);
            while (try iter.next(allocator)) |row| {
                const new_row_ptr = try row_acc.addOne();
                new_row_ptr.* = row;
            }

            const num_cols = iter.result_set.col_defs.len;
            var rows = try allocator.alloc([]?[]const u8, row_acc.items.len); //TODO: alloc once inst instead
            var elems = try allocator.alloc(?[]const u8, row_acc.items.len * num_cols);
            for (row_acc.items, 0..) |row, i| {
                const dest_row = elems[i * num_cols .. (i + 1) * num_cols];
                const data = try row.expect(.data);
                try data.scan(dest_row);
                rows[i] = dest_row;
            }

            return .{
                .result_rows = try row_acc.toOwnedSlice(),
                .elems = elems,
                .rows = rows,
            };
        }

        pub fn collectStructs(iter: *const ResultSetIter(BinaryResultData), comptime Struct: type, allocator: std.mem.Allocator) !TableStructs(Struct) {
            var row_acc = std.ArrayList(ResultRow(BinaryResultData)).init(allocator);
            while (try iter.next(allocator)) |row| {
                const new_row_ptr = try row_acc.addOne();
                new_row_ptr.* = row;
            }

            const structs = try allocator.alloc(Struct, row_acc.items.len);
            for (row_acc.items, structs) |row, *s| {
                const data = try row.expect(.data);
                try data.scan(s);
            }

            return .{
                .result_rows = try row_acc.toOwnedSlice(),
                .rows = structs,
            };
        }
    };
}

pub const TableTexts = struct {
    result_rows: []const ResultRow(TextResultData),
    elems: []const ?[]const u8,
    rows: []const []const ?[]const u8,

    pub fn deinit(t: *const TableTexts, allocator: std.mem.Allocator) void {
        for (t.result_rows) |row| {
            row.deinit(allocator);
        }
        allocator.free(t.result_rows);
        allocator.free(t.rows);
        allocator.free(t.elems);
    }

    pub fn debugPrint(t: *const TableTexts) void {
        const print = std.debug.print;
        for (t.rows, 0..) |row, i| {
            print("row: {d} -> ", .{i});
            print("|", .{});
            for (row) |elem| {
                print("{?s}", .{elem});
                print("|", .{});
            }
            print("\n", .{});
        }
    }
};

pub fn TableStructs(comptime Struct: type) type {
    return struct {
        result_rows: []const ResultRow(BinaryResultData),
        rows: []const Struct,

        pub fn deinit(t: *const TableStructs(Struct), allocator: std.mem.Allocator) void {
            for (t.result_rows) |row| {
                row.deinit(allocator);
            }
            allocator.free(t.result_rows);
            allocator.free(t.rows);
        }

        pub fn debugPrint(t: *const TableStructs(Struct)) void {
            const print = std.debug.print;
            for (t.rows, 0..) |row, i| {
                print("row: {d} -> ", .{i});
                print("{any}", .{row});
                print("\n", .{});
            }
        }
    };
}
