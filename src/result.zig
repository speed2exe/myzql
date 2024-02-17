const std = @import("std");
const protocol = @import("./protocol.zig");
const constants = @import("./constants.zig");
const prep_stmts = protocol.prepared_statements;
const PrepareOk = prep_stmts.PrepareOk;
const Packet = protocol.packet.Packet;
const PayloadReader = protocol.packet.PayloadReader;
const OkPacket = protocol.generic_response.OkPacket;
const ErrorPacket = protocol.generic_response.ErrorPacket;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;
const Conn = @import("./conn.zig").Conn;
const EofPacket = protocol.generic_response.EofPacket;
const conversion = @import("./conversion.zig");

pub fn QueryResult(comptime T: type) type {
    return union(enum) {
        ok: OkPacket,
        err: ErrorPacket,
        rows: ResultSet(T),

        // allocation happens when a result set is returned
        pub fn init(c: *Conn, allocator: std.mem.Allocator) !QueryResult(T) {
            const packet = try c.readPacket();
            return switch (packet.payload[0]) {
                constants.OK => .{ .ok = OkPacket.init(&packet, c.client_capabilities) },
                constants.ERR => .{ .err = ErrorPacket.init(&packet) },
                constants.LOCAL_INFILE_REQUEST => _ = @panic("not implemented"),
                else => .{ .rows = try ResultSet(T).init(allocator, c, &packet) },
            };
        }

        pub fn deinit(q: *const QueryResult(T), allocator: std.mem.Allocator) void {
            switch (q.*) {
                .rows => |rows| rows.deinit(allocator),
                else => {},
            }
        }

        pub fn expect(
            q: QueryResult(T),
            comptime value_variant: std.meta.FieldEnum(QueryResult(T)),
        ) !std.meta.FieldType(QueryResult(T), value_variant) {
            return switch (q) {
                value_variant => @field(q, @tagName(value_variant)),
                else => {
                    return switch (q) {
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

        pub fn init(allocator: std.mem.Allocator, conn: *Conn, packet: *const Packet) !ResultSet(T) {
            var reader = packet.reader();
            const n_columns = reader.readLengthEncodedInteger();
            std.debug.assert(reader.finished());

            const col_packets = try allocator.alloc(Packet, n_columns);
            errdefer allocator.free(col_packets);

            const col_defs = try allocator.alloc(ColumnDefinition41, n_columns);
            errdefer allocator.free(col_defs);

            for (col_packets, col_defs) |*pac, *def| {
                const col_def_packet = try conn.readPacket();
                pac.* = try col_def_packet.cloneAlloc(allocator);
                def.* = ColumnDefinition41.init(&col_def_packet);
            }

            return .{
                .conn = conn,
                .col_packets = col_packets,
                .col_defs = col_defs,
            };
        }

        fn deinit(r: *const ResultSet(T), allocator: std.mem.Allocator) void {
            for (r.col_packets) |packet| {
                packet.deinit(allocator);
            }
            allocator.free(r.col_packets);
            allocator.free(r.col_defs);
        }

        pub fn readRow(r: *const ResultSet(T)) !ResultRow(T) {
            return ResultRow(T).init(r.conn, r.col_defs);
        }

        pub fn tableTexts(r: *const ResultSet(TextResultRow), allocator: std.mem.Allocator) !TableTexts {
            const all_rows = try collectAllRowsPacketUntilEof(r.conn, allocator);
            errdefer deinitOwnedPacketList(all_rows);
            return try TableTexts.init(all_rows, allocator, r.col_defs.len);
        }

        pub fn iter(r: *const ResultSet(T)) ResultRowIter(T) {
            return .{ .result_set = r };
        }
    };
}

pub const TextResultRow = struct {
    packet: Packet,
    col_defs: []const ColumnDefinition41,

    pub fn iter(t: *const TextResultRow) TextElemIter {
        return TextElemIter.init(&t.packet);
    }

    pub fn textElems(t: *const TextResultRow, allocator: std.mem.Allocator) !TextElems {
        return TextElems.init(&t.packet, allocator, t.col_defs.len);
    }
};

pub const TextElems = struct {
    packet: Packet,
    elems: []const ?[]const u8,

    pub fn init(p: *const Packet, allocator: std.mem.Allocator, n: usize) !TextElems {
        const packet = try p.cloneAlloc(allocator);
        errdefer packet.deinit(allocator);
        const elems = try allocator.alloc(?[]const u8, n);
        scanTextResultRow(elems, &packet);
        return .{ .packet = packet, .elems = elems };
    }

    pub fn deinit(t: *const TextElems, allocator: std.mem.Allocator) void {
        t.packet.deinit(allocator);
        allocator.free(t.elems);
    }
};

pub const TextElemIter = struct {
    reader: PayloadReader,

    pub fn init(packet: *const Packet) TextElemIter {
        return .{ .reader = packet.reader() };
    }

    pub fn next(i: *TextElemIter) ??[]const u8 {
        const first_byte = i.reader.peek() orelse return null;
        if (first_byte == constants.TEXT_RESULT_ROW_NULL) {
            i.reader.skipComptime(1);
            return @as(?[]const u8, null);
        }
        return i.reader.readLengthEncodedString();
    }
};

fn scanTextResultRow(dest: []?[]const u8, packet: *const Packet) void {
    var reader = packet.reader();
    for (dest) |*d| {
        d.* = blk: {
            const first_byte = reader.peek() orelse unreachable;
            if (first_byte == constants.TEXT_RESULT_ROW_NULL) {
                reader.skipComptime(1);
                break :blk null;
            }
            break :blk reader.readLengthEncodedString();
        };
    }
}

pub const BinaryResultRow = struct {
    packet: Packet,
    col_defs: []const ColumnDefinition41,

    // dest: pointer to a struct
    // string types like []u8, []const u8, ?[]u8 are shallow copied, data may be invalidated
    // from next scan, or network request.
    // use structCreate and structDestroy to allocate and deallocate struct objects
    // from binary result values
    pub fn scan(b: *const BinaryResultRow, dest: anytype) !void {
        try conversion.scanBinResultRow(dest, &b.packet, b.col_defs, null);
    }

    // returns a pointer to allocated struct object, caller must remember to call structDestroy
    // after use
    pub fn structCreate(b: *const BinaryResultRow, comptime Struct: type, allocator: std.mem.Allocator) !*Struct {
        const s = try allocator.create(Struct);
        try conversion.scanBinResultRow(s, &b.packet, b.col_defs, allocator);
        return s;
    }

    // deallocate struct object created from `structCreate`
    // s: *Struct
    pub fn structDestroy(s: anytype, allocator: std.mem.Allocator) void {
        structFreeDynamic(s.*, allocator);
        allocator.destroy(s);
    }

    fn structFreeDynamic(s: anytype, allocator: std.mem.Allocator) void {
        const s_ti = @typeInfo(@TypeOf(s)).Struct;
        inline for (s_ti.fields) |field| {
            structFreeStr(field.type, @field(s, field.name), allocator);
        }
    }

    fn structFreeStr(comptime StructField: type, value: StructField, allocator: std.mem.Allocator) void {
        switch (@typeInfo(StructField)) {
            .Pointer => |p| switch (@typeInfo(p.child)) {
                .Int => |int| if (int.bits == 8) allocator.free(value),
                else => {},
            },
            .Optional => |o| if (value) |some| structFreeStr(o.child, some, allocator),
            else => {},
        }
    }
};

pub fn ResultRow(comptime T: type) type {
    return union(enum) {
        err: ErrorPacket,
        ok: OkPacket,
        row: T,

        fn init(conn: *Conn, col_defs: []const ColumnDefinition41) !ResultRow(T) {
            const packet = try conn.readPacket();
            return switch (packet.payload[0]) {
                constants.ERR => .{ .err = ErrorPacket.init(&packet) },
                constants.EOF => .{ .ok = OkPacket.init(&packet, conn.client_capabilities) },
                else => .{ .row = .{ .packet = packet, .col_defs = col_defs } },
            };
        }

        pub fn expect(
            r: ResultRow(T),
            comptime value_variant: std.meta.FieldEnum(ResultRow(T)),
        ) !std.meta.FieldType(ResultRow(T), value_variant) {
            return switch (r) {
                value_variant => @field(r, @tagName(value_variant)),
                else => {
                    return switch (r) {
                        .err => |err| return err.asError(),
                        .ok => |ok| {
                            std.log.err("Unexpected OkPacket: {any}\n", .{ok});
                            return error.UnexpectedOk;
                        },
                        .row => |data| {
                            std.log.err("Unexpected Row: {any}\n", .{data});
                            return error.UnexpectedResultData;
                        },
                    };
                },
            };
        }
    };
}

fn deinitOwnedPacketList(packet_list: std.ArrayList(Packet)) void {
    for (packet_list.items) |packet| {
        packet.deinit(packet_list.allocator);
    }
    packet_list.deinit();
}

fn collectAllRowsPacketUntilEof(conn: *Conn, allocator: std.mem.Allocator) !std.ArrayList(Packet) {
    var packet_list = std.ArrayList(Packet).init(allocator);
    errdefer deinitOwnedPacketList(packet_list);

    // Accumulate all packets until EOF
    while (true) {
        const packet = try conn.readPacket();
        return switch (packet.payload[0]) {
            constants.ERR => ErrorPacket.init(&packet).asError(),
            constants.EOF => {
                _ = OkPacket.init(&packet, conn.client_capabilities);
                return packet_list;
            },
            else => {
                const owned_packet = try packet.cloneAlloc(allocator);
                try packet_list.append(owned_packet);
                continue;
            },
        };
    }
}

pub const PrepareResult = union(enum) {
    err: ErrorPacket,
    stmt: PreparedStatement,

    pub fn init(conn: *Conn, allocator: std.mem.Allocator) !PrepareResult {
        const response_packet = try conn.readPacket();
        return switch (response_packet.payload[0]) {
            constants.ERR => .{ .err = ErrorPacket.init(&response_packet) },
            constants.OK => .{ .stmt = try PreparedStatement.init(&response_packet, conn, allocator) },
            else => return response_packet.asError(),
        };
    }

    pub fn deinit(p: *const PrepareResult, allocator: std.mem.Allocator) void {
        switch (p.*) {
            .stmt => |prep_stmt| prep_stmt.deinit(allocator),
            else => {},
        }
    }

    pub fn expect(
        p: PrepareResult,
        comptime value_variant: std.meta.FieldEnum(PrepareResult),
    ) !std.meta.FieldType(PrepareResult, value_variant) {
        return switch (p) {
            value_variant => @field(p, @tagName(value_variant)),
            else => {
                return switch (p) {
                    .err => |err| return err.asError(),
                    .stmt => |ok| {
                        std.log.err("Unexpected PreparedStatement: {any}\n", .{ok});
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

    pub fn init(ok_packet: *const Packet, conn: *Conn, allocator: std.mem.Allocator) !PreparedStatement {
        const prep_ok = PrepareOk.init(ok_packet, conn.client_capabilities);

        const col_count = prep_ok.num_params + prep_ok.num_columns;

        const packets = try allocator.alloc(Packet, col_count);
        @memset(packets, .{ .sequence_id = 0, .payload = &.{} });
        errdefer {
            for (packets) |packet| {
                packet.deinit(allocator);
            }
            allocator.free(packets);
        }

        const col_defs = try allocator.alloc(ColumnDefinition41, col_count);
        errdefer allocator.free(col_defs);

        for (packets, col_defs) |*packet, *col_def| {
            packet.* = try (try conn.readPacket()).cloneAlloc(allocator);
            col_def.* = ColumnDefinition41.init(packet);
        }

        return .{
            .prep_ok = prep_ok,
            .packets = packets,
            .col_defs = col_defs,
            .params = col_defs[0..prep_ok.num_params],
            .res_cols = col_defs[prep_ok.num_params..],
        };
    }

    fn deinit(prep_stmt: *const PreparedStatement, allocator: std.mem.Allocator) void {
        allocator.free(prep_stmt.col_defs);
        for (prep_stmt.packets) |packet| {
            packet.deinit(allocator);
        }
        allocator.free(prep_stmt.packets);
    }
};

pub fn ResultRowIter(comptime T: type) type {
    return struct {
        result_set: *const ResultSet(T),

        pub fn next(iter: *const ResultRowIter(T)) !?T {
            const row_res = try iter.result_set.readRow();
            return switch (row_res) {
                .ok => return null,
                .err => |err| err.asError(),
                .row => |row| row,
            };
        }

        pub fn tableStructs(iter: *const ResultRowIter(BinaryResultRow), comptime Struct: type, allocator: std.mem.Allocator) !TableStructs(Struct) {
            return TableStructs(Struct).init(iter, allocator);
        }
    };
}

pub const TableTexts = struct {
    packet_list: std.ArrayList(Packet),

    flattened: []const ?[]const u8,
    table: []const []const ?[]const u8,

    fn init(packet_list: std.ArrayList(Packet), allocator: std.mem.Allocator, n_cols: usize) !TableTexts {
        var table = try allocator.alloc([]?[]const u8, packet_list.items.len); // TODO: alloc once instead
        errdefer allocator.free(table);
        var flattened = try allocator.alloc(?[]const u8, packet_list.items.len * n_cols);

        for (packet_list.items, 0..) |packet, i| {
            const dest_row = flattened[i * n_cols .. (i + 1) * n_cols];
            scanTextResultRow(dest_row, &packet);
            table[i] = dest_row;
        }

        return .{
            .packet_list = packet_list,
            .flattened = flattened,
            .table = table,
        };
    }

    pub fn deinit(t: *const TableTexts, allocator: std.mem.Allocator) void {
        deinitOwnedPacketList(t.packet_list);
        allocator.free(t.table);
        allocator.free(t.flattened);
    }

    pub fn debugPrint(t: *const TableTexts) !void {
        const w = std.io.getStdOut().writer();
        for (t.table, 0..) |row, i| {
            try w.print("row: {d} -> ", .{i});
            try w.print("|", .{});
            for (row) |elem| {
                try w.print("{?s}", .{elem});
                try w.print("|", .{});
            }
            try w.print("\n", .{});
        }
    }
};

pub fn TableStructs(comptime Struct: type) type {
    return struct {
        struct_list: std.ArrayList(Struct),

        pub fn init(iter: *const ResultRowIter(BinaryResultRow), allocator: std.mem.Allocator) !TableStructs(Struct) {
            var struct_list = std.ArrayList(Struct).init(allocator);
            while (try iter.next()) |row| {
                const new_struct_ptr = try struct_list.addOne();
                try conversion.scanBinResultRow(new_struct_ptr, &row.packet, row.col_defs, null);
            }
            return .{ .struct_list = struct_list };
        }

        pub fn deinit(t: *const TableStructs(Struct), allocator: std.mem.Allocator) void {
            for (t.struct_list.items) |s| {
                BinaryResultRow.structFreeDynamic(s, allocator);
            }
            t.struct_list.deinit();
        }

        pub fn debugPrint(t: *const TableStructs(Struct)) void {
            const w = std.io.getStdOut().writer();
            for (t.struct_list.items, 0..) |row, i| {
                try w.print("row: {d} -> ", .{i});
                try w.print("{any}", .{row});
                try w.print("\n", .{});
            }
        }
    };
}
