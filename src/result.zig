const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const protocol = @import("./protocol.zig");
const constants = @import("./constants.zig");
const prep_stmts = protocol.prepared_statements;
const PrepareOk = prep_stmts.PrepareOk;
const Packet = protocol.packet.Packet;
const PayloadReader = protocol.packet.PayloadReader;
const OkPacket = protocol.generic_response.OkPacket;
const ErrorPacket = protocol.generic_response.ErrorPacket;
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;
const PacketReader = protocol.packet_reader.PacketReader;
const Conn = @import("./conn.zig").Conn;
const conversion = @import("./conversion.zig");

/// Result of a query that does not return rows.
/// Use `.expect(.ok)` to get the `OkPacket`, or `.expect(.err)` to get the `ErrorPacket`.
pub const QueryResult = union(enum) {
    ok: OkPacket,
    err: ErrorPacket,

    pub fn init(packet: *const Packet, capabilities: u32) !QueryResult {
        return switch (packet.payload[0]) {
            constants.OK => .{ .ok = OkPacket.init(packet, capabilities) },
            constants.ERR => .{ .err = ErrorPacket.init(packet) },
            constants.LOCAL_INFILE_REQUEST => _ = @panic("not implemented"),
            else => {
                std.log.warn(
                    \\Unexpected packet: {any}\n,
                    \\Are you expecting a result set? If so, use QueryResultRows instead.
                    \\This is unrecoverable error.
                , .{packet});
                return error.UnrecoverableError;
            },
        };
    }

    /// Unwrap the result to the given variant, returning an error if it does not match.
    /// If the result is `.err`, the error packet's message is logged and returned as a Zig error.
    pub fn expect(
        q: QueryResult,
        comptime value_variant: std.meta.FieldEnum(QueryResult),
    ) !@FieldType(QueryResult, @tagName(value_variant)) {
        return switch (q) {
            value_variant => @field(q, @tagName(value_variant)),
            else => {
                return switch (q) {
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

/// Result of a query that returns rows (from `Conn.queryRows` or `Conn.executeRows`).
/// T is either `TextResultRow` (from `queryRows`) or `BinaryResultRow` (from `executeRows`).
/// Use `.expect(.rows)` to get the `ResultSet(T)`, or `.expect(.err)` to get the `ErrorPacket`.
pub fn QueryResultRows(comptime T: type) type {
    return union(enum) {
        err: ErrorPacket,
        rows: ResultSet(T),

        // allocation happens when a result set is returned
        pub fn init(c: *Conn, allocator: Allocator) !QueryResultRows(T) {
            const packet = try c.readPacket();
            return switch (packet.payload[0]) {
                constants.OK => {
                    std.log.warn(
                        \\Unexpected OkPacket: {any}\n,
                        \\If your query is not expecting a result set, use QueryResult instead.
                    , .{OkPacket.init(&packet, c.capabilities)});
                    return packet.asError();
                },
                constants.ERR => .{ .err = ErrorPacket.init(&packet) },
                constants.LOCAL_INFILE_REQUEST => _ = @panic("not implemented"),
                else => .{ .rows = try ResultSet(T).init(c, allocator, &packet) },
            };
        }

        /// Unwrap the result to the given variant, returning an error if it does not match.
        /// If the result is `.err`, the error packet's message is logged and returned as a Zig error.
        ///
        /// Example:
        /// ```zig
        /// const result: QueryResultRows(TextResultRow) = try conn.queryRows(allocator, "SELECT * FROM table");
        /// const rows: ResultSet(TextResultRow) = try result.expect(.rows);
        /// ```
        pub fn expect(
            q: QueryResultRows(T),
            comptime value_variant: std.meta.FieldEnum(QueryResultRows(T)),
        ) !@FieldType(QueryResultRows(T), @tagName(value_variant)) {
            return switch (q) {
                value_variant => @field(q, @tagName(value_variant)),
                else => {
                    return switch (q) {
                        .err => |err| return err.asError(),
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

/// A result set returned by a query that produces rows.
/// T is either `TextResultRow` (from `queryRows`) or `BinaryResultRow` (from `executeRows`).
/// Use `iter()` to iterate over rows, `first()` to get only the first row,
/// or `tableTexts()` / `tableStructs()` (via the iterator) to collect all rows at once.
pub fn ResultSet(comptime T: type) type {
    return struct {
        conn: *Conn,
        col_defs: []const ColumnDefinition41,

        pub fn init(conn: *Conn, allocator: Allocator, packet: *const Packet) !ResultSet(T) {
            var reader = packet.reader();
            const n_columns = reader.readLengthEncodedInteger();
            std.debug.assert(reader.finished());

            try conn.readPutResultColumns(allocator, n_columns);

            return .{
                .conn = conn,
                .col_defs = conn.result_meta.col_defs.items,
            };
        }

        fn deinit(r: *const ResultSet(T), allocator: Allocator) void {
            for (r.col_packets) |packet| {
                packet.deinit(allocator);
            }
            allocator.free(r.col_packets);
            allocator.free(r.col_defs);
        }

        pub fn readRow(r: *const ResultSet(T)) !ResultRow(T) {
            return ResultRow(T).init(r.conn, r.col_defs);
        }

        /// Collect all text result rows into a `TableTexts` struct.
        /// Allocates memory; caller must call `deinit` on the returned value.
        pub fn tableTexts(r: *ResultSet(TextResultRow), allocator: Allocator) !TableTexts {
            var all_rows = try collectAllRowsPacketUntilEof(r.conn, allocator);
            errdefer deinitOwnedPacketList(allocator, &all_rows);
            return try TableTexts.init(all_rows, allocator, r.col_defs.len);
        }

        /// Return the first row of the result set, draining remaining rows.
        /// Returns `null` if the result set is empty.
        pub fn first(r: *const ResultSet(T)) !?T {
            const row_res = try r.readRow();
            return switch (row_res) {
                .ok => null,
                .err => |err| err.asError(),
                .row => |row| blk: {
                    const reader = &r.conn.reader;

                    // Drain any full packets already buffered in conn.reader.
                    // Advancing pos alone won't trigger buffer reallocation,
                    // so the first row's packet payload stays valid.
                    drain_buffered: while (reader.pos + 4 <= reader.len) {
                        const hdr = reader.buf[reader.pos..];
                        const payload_len = std.mem.readInt(u24, hdr[0..3], .little);
                        if (reader.pos + 4 + payload_len > reader.len) break :drain_buffered;
                        const pkt_type = hdr[4];
                        reader.pos += 4 + payload_len;
                        switch (pkt_type) {
                            constants.ERR => return error.ErrorPacket,
                            constants.EOF => break :blk row,
                            else => continue :drain_buffered,
                        }
                    }

                    // Drain remaining rows from the stream through a temporary
                    // reader so conn.reader's buffer is never expanded or moved.
                    var temp_reader = try PacketReader.init(
                        reader.allocator,
                        reader.io,
                        reader.stream,
                    );
                    defer temp_reader.deinit();

                    // Feed any partial buffered data into the temp reader.
                    if (reader.pos < reader.len) {
                        const tail = try reader.allocator.dupe(u8, reader.buf[reader.pos..reader.len]);
                        reader.pos = reader.len;
                        temp_reader.buf = tail;
                        temp_reader.len = tail.len;
                    }

                    while (true) {
                        const pkt = try temp_reader.readPacket();
                        switch (pkt.payload[0]) {
                            constants.ERR => return ErrorPacket.init(&pkt).asError(),
                            constants.EOF => break,
                            else => continue,
                        }
                    }
                    break :blk row;
                },
            };
        }

        /// Return an iterator over the rows in this result set.
        /// Note: rows are read from the network; the iterator can only be used once.
        /// All rows must be consumed (iterated to `null`) before issuing another query.
        pub fn iter(r: *const ResultSet(T)) ResultRowIter(T) {
            return .{ .result_set = r };
        }
    };
}

/// A single row returned by a text protocol query (`Conn.queryRows`).
/// Use `iter()` to iterate over raw text elements,
/// or `textElems()` to collect all elements into an allocated slice.
pub const TextResultRow = struct {
    packet: Packet,
    col_defs: []const ColumnDefinition41,

    pub fn iter(t: *const TextResultRow) TextElemIter {
        return TextElemIter.init(&t.packet);
    }

    pub fn textElems(t: *const TextResultRow, allocator: Allocator) !TextElems {
        return TextElems.init(&t.packet, allocator, t.col_defs.len);
    }
};

pub const TextElems = struct {
    packet: Packet,
    elems: []const ?[]const u8,

    pub fn init(p: *const Packet, allocator: Allocator, n: usize) !TextElems {
        const packet = try p.cloneAlloc(allocator);
        errdefer packet.deinit(allocator);
        const elems = try allocator.alloc(?[]const u8, n);
        scanTextResultRow(elems, &packet);
        return .{ .packet = packet, .elems = elems };
    }

    pub fn deinit(t: *const TextElems, allocator: Allocator) void {
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

/// A single row returned by a binary protocol query (`Conn.executeRows`).
/// Use `scan` to scan row values into an existing struct,
/// or `structCreate` to allocate a new struct (must be freed with `structDestroy`).
pub const BinaryResultRow = struct {
    packet: Packet,
    col_defs: []const ColumnDefinition41,

    /// Scan the row into the struct pointed to by `dest`.
    /// String fields (`[]u8`, `[]const u8`) are shallow-copied and point into the row's
    /// internal buffer, which is invalidated on the next `scan` call or network request.
    /// Use `structCreate` if you need the data to outlive the current row.
    pub fn scan(b: *const BinaryResultRow, dest: anytype) !void {
        try conversion.scanBinResultRow(dest, &b.packet, b.col_defs, null);
    }

    /// Allocate a new struct of type `Struct` and scan the row values into it.
    /// String fields are heap-allocated and owned by the returned struct.
    /// The caller must call `structDestroy` to free the struct and any owned strings.
    pub fn structCreate(b: *const BinaryResultRow, comptime Struct: type, allocator: Allocator) !*Struct {
        const s = try allocator.create(Struct);
        try conversion.scanBinResultRow(s, &b.packet, b.col_defs, allocator);
        return s;
    }

    /// Free a struct allocated by `structCreate`, including any owned string fields.
    /// `s` must be a pointer to the struct returned by `structCreate`.
    pub fn structDestroy(s: anytype, allocator: Allocator) void {
        structFreeDynamic(s.*, allocator);
        allocator.destroy(s);
    }

    fn structFreeDynamic(s: anytype, allocator: Allocator) void {
        const s_ti = @typeInfo(@TypeOf(s)).@"struct";
        inline for (s_ti.field_names, s_ti.field_types) |field_name, field_type| {
            structFreeStr(field_type, @field(s, field_name), allocator);
        }
    }

    fn structFreeStr(comptime StructField: type, value: StructField, allocator: Allocator) void {
        switch (@typeInfo(StructField)) {
            .pointer => |p| switch (@typeInfo(p.child)) {
                .int => |int| if (int.bits == 8) {
                    allocator.free(value);
                },
                else => {},
            },
            .optional => |o| if (value) |some| structFreeStr(o.child, some, allocator),
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
                constants.EOF => .{ .ok = OkPacket.init(&packet, conn.capabilities) },
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

fn deinitOwnedPacketList(allocator: Allocator, packet_list: *std.ArrayList(Packet)) void {
    for (packet_list.items) |packet| {
        packet.deinit(allocator);
    }
    packet_list.deinit(allocator);
}

fn collectAllRowsPacketUntilEof(conn: *Conn, allocator: Allocator) !std.ArrayList(Packet) {
    var packet_list: std.ArrayList(Packet) = .empty;
    errdefer deinitOwnedPacketList(allocator, &packet_list);

    // Accumulate all packets until EOF
    while (true) {
        const packet = try conn.readPacket();
        return switch (packet.payload[0]) {
            constants.ERR => ErrorPacket.init(&packet).asError(),
            constants.EOF => {
                _ = OkPacket.init(&packet, conn.capabilities);
                return packet_list;
            },
            else => {
                const owned_packet = try packet.cloneAlloc(allocator);
                try packet_list.append(allocator, owned_packet);
                continue;
            },
        };
    }
}

/// Result of `Conn.prepare`. Use `.expect(.stmt)` to get the `PreparedStatement`,
/// or `.expect(.err)` to get the `ErrorPacket`.
/// The caller must call `deinit` to free resources associated with a successful prepare.
pub const PrepareResult = union(enum) {
    err: ErrorPacket,
    stmt: PreparedStatement,

    pub fn init(c: *Conn, allocator: Allocator) !PrepareResult {
        const response_packet = try c.readPacket();
        return switch (response_packet.payload[0]) {
            constants.ERR => .{ .err = ErrorPacket.init(&response_packet) },
            constants.OK => .{ .stmt = try PreparedStatement.init(&response_packet, c, allocator) },
            else => return response_packet.asError(),
        };
    }

    /// Free resources held by this `PrepareResult`.
    /// Must be called when the prepare result is no longer needed.
    pub fn deinit(p: *const PrepareResult, allocator: Allocator) void {
        switch (p.*) {
            .stmt => |prep_stmt| prep_stmt.deinit(allocator),
            else => {},
        }
    }

    /// Unwrap the result to the given variant, returning an error if it does not match.
    /// If the result is `.err`, the error packet's message is logged and returned as a Zig error.
    pub fn expect(
        p: PrepareResult,
        comptime value_variant: std.meta.FieldEnum(PrepareResult),
    ) !@FieldType(PrepareResult, @tagName(value_variant)) {
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

/// A prepared statement returned by `Conn.prepare`.
/// Pass a pointer to this to `Conn.execute` or `Conn.executeRows` to run the query.
/// Resources are freed when `PrepareResult.deinit` is called.
pub const PreparedStatement = struct {
    prep_ok: PrepareOk,
    packets: []const Packet,
    col_defs: []const ColumnDefinition41,
    /// Parameter column definitions (corresponding to `?` placeholders in the query).
    params: []const ColumnDefinition41,
    /// Result column definitions (columns returned by the query).
    res_cols: []const ColumnDefinition41,

    pub fn init(ok_packet: *const Packet, conn: *Conn, allocator: Allocator) !PreparedStatement {
        const prep_ok = PrepareOk.init(ok_packet, conn.capabilities);

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

    fn deinit(prep_stmt: *const PreparedStatement, allocator: Allocator) void {
        allocator.free(prep_stmt.col_defs);
        for (prep_stmt.packets) |packet| {
            packet.deinit(allocator);
        }
        allocator.free(prep_stmt.packets);
    }
};

/// An iterator over rows in a `ResultSet`.
/// T is either `TextResultRow` or `BinaryResultRow`.
/// Rows are read from the network on each call to `next()`.
/// All rows must be consumed before issuing another query on the same connection.
pub fn ResultRowIter(comptime T: type) type {
    return struct {
        result_set: *const ResultSet(T),

        /// Advance the iterator and return the next row, or `null` at end-of-results.
        /// Returns an error if the server sends an error packet.
        pub fn next(iter: *const ResultRowIter(T)) !?T {
            const row_res = try iter.result_set.readRow();
            return switch (row_res) {
                .ok => return null,
                .err => |err| err.asError(),
                .row => |row| row,
            };
        }

        /// Collect all remaining rows into a `TableStructs(Struct)`.
        /// Allocates memory; caller must call `deinit` on the returned value.
        /// Only available when T is `BinaryResultRow`.
        pub fn tableStructs(iter: *const ResultRowIter(BinaryResultRow), comptime Struct: type, allocator: Allocator) !TableStructs(Struct) {
            return TableStructs(Struct).init(iter, allocator);
        }
    };
}

/// A collection of all text result rows from a query, held in memory.
/// Obtained via `ResultSet(TextResultRow).tableTexts(allocator)`.
/// The `table` field is a slice of rows, each row being a slice of nullable strings.
/// Call `deinit` to free all memory.
pub const TableTexts = struct {
    packet_list: std.ArrayList(Packet),

    flattened: []const ?[]const u8,
    table: []const []const ?[]const u8,

    fn init(packet_list: std.ArrayList(Packet), allocator: Allocator, n_cols: usize) !TableTexts {
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

    pub fn deinit(t: *TableTexts, allocator: Allocator) void {
        deinitOwnedPacketList(allocator, &t.packet_list);
        allocator.free(t.table);
        allocator.free(t.flattened);
    }

    pub fn debugPrint(t: *const TableTexts) !void {
        var buffer: [1024]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buffer).interface;
        for (t.table, 0..) |row, i| {
            try w.print("row: {d} -> ", .{i});
            try w.print("|", .{});
            for (row) |elem| {
                try w.print("{?s}", .{elem});
                try w.print("|", .{});
            }
            try w.print("\n", .{});
        }
        try w.flush();
    }
};

/// A collection of all binary result rows scanned into structs of type `Struct`.
/// Obtained via `ResultRowIter(BinaryResultRow).tableStructs(Struct, allocator)`.
/// The `struct_list` field is a list of all rows as `Struct` values.
/// Call `deinit` to free all memory, including any heap-allocated string fields within structs.
pub fn TableStructs(comptime Struct: type) type {
    return struct {
        struct_list: std.ArrayList(Struct),

        pub fn init(iter: *const ResultRowIter(BinaryResultRow), allocator: Allocator) !TableStructs(Struct) {
            var struct_list: std.ArrayList(Struct) = .empty;
            while (try iter.next()) |row| {
                const new_struct_ptr = try struct_list.addOne(allocator);
                try conversion.scanBinResultRow(new_struct_ptr, &row.packet, row.col_defs, allocator);
            }
            return .{ .struct_list = struct_list };
        }

        pub fn deinit(t: *TableStructs(Struct), allocator: Allocator) void {
            for (t.struct_list.items) |s| {
                BinaryResultRow.structFreeDynamic(s, allocator);
            }
            t.struct_list.deinit(allocator);
        }

        pub fn debugPrint(t: *const TableStructs(Struct)) !void {
            const w = std.io.getStdOut().writer();
            for (t.struct_list.items, 0..) |row, i| {
                try w.print("row: {any} -> ", .{i});
                try w.print("{any}", .{row});
                try w.print("\n", .{});
            }
        }
    };
}
