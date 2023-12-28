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
const helper = @import("./helper.zig");
const ResultSetIter = helper.ResultSetIter;
const PacketReader = @import("./protocol/packet_reader.zig").PacketReader;

pub fn QueryResult(comptime ResultRowType: type) type {
    return struct {
        const Value = union(enum) {
            ok: *const OkPacket,
            err: *const ErrorPacket,
            rows: ResultSet(ResultRowType),
        };
        packet: Packet,
        value: Value,

        pub fn init(conn: *Conn, allocator: std.mem.Allocator) !QueryResult(ResultRowType) {
            const response_packet = try conn.readPacket(allocator);
            return .{
                .packet = response_packet,
                .value = switch (response_packet.payload[0]) {
                    constants.OK => .{ .ok = &OkPacket.initFromPacket(&response_packet, conn.client_capabilities) },
                    constants.ERR => .{ .err = &ErrorPacket.initFromPacket(false, &response_packet, conn.client_capabilities) },
                    constants.LOCAL_INFILE_REQUEST => _ = @panic("not implemented"),
                    else => .{ .rows = blk: {
                        var packet_reader = PacketReader.initFromPacket(&response_packet);
                        const column_count = packet_reader.readLengthEncodedInteger();
                        std.debug.assert(packet_reader.finished());
                        break :blk try ResultSet(ResultRowType).init(allocator, conn, column_count);
                    } },
                },
            };
        }

        pub fn deinit(q: *const QueryResult(ResultRowType), allocator: std.mem.Allocator) void {
            q.packet.deinit(allocator);
            switch (q.value) {
                .rows => |rows| rows.deinit(allocator),
                else => {},
            }
        }

        pub fn expect(
            q: *const QueryResult(ResultRowType),
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

pub fn ResultSet(comptime ResultRowType: type) type {
    return struct {
        conn: *Conn,
        col_packets: []const Packet,
        col_defs: []const ColumnDefinition41,

        pub fn init(allocator: std.mem.Allocator, conn: *Conn, column_count: u64) !ResultSet(ResultRowType) {
            const col_packets = try allocator.alloc(Packet, column_count);
            @memset(col_packets, Packet.safe_deinit());
            const col_defs = try allocator.alloc(ColumnDefinition41, column_count);

            for (col_packets, col_defs) |*pac, *def| {
                pac.* = try conn.readPacket(allocator);
                def.* = ColumnDefinition41.initFromPacket(pac);
            }

            try discardEofPacket(conn, allocator);

            return .{ .conn = conn, .col_packets = col_packets, .col_defs = col_defs };
        }

        fn deinit(t: *const ResultSet(ResultRowType), allocator: std.mem.Allocator) void {
            for (t.col_packets) |packet| {
                packet.deinit(allocator);
            }
            allocator.free(t.col_packets);
            allocator.free(t.col_defs);
        }

        pub fn readRow(t: *const ResultSet(ResultRowType), allocator: std.mem.Allocator) !ResultRowType {
            const packet = try t.conn.readPacket(allocator);
            return .{
                .result_set = t,
                .packet = packet,
                .value = switch (packet.payload[0]) {
                    constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &packet, t.conn.client_capabilities) },
                    constants.EOF => .{ .eof = EofPacket.initFromPacket(&packet, t.conn.client_capabilities) },
                    else => .{ .raw = packet.payload },
                },
            };
        }

        pub fn iter(t: *const ResultSet(ResultRowType)) ResultSetIter(ResultRowType) {
            return .{ .result_set = t };
        }
    };
}

pub const TextResultRow = struct {
    result_set: *const ResultSet(TextResultRow),
    packet: Packet,
    value: union(enum) {
        err: ErrorPacket,
        eof: EofPacket,

        //https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query_response_text_resultset_row.html
        raw: []const u8,
    },

    pub fn scan(t: *const TextResultRow, dest: []?[]const u8) !void {
        std.debug.assert(dest.len == t.result_set.col_defs.len);
        switch (t.value) {
            .err => |err| return err.asError(),
            .eof => |eof| return eof.asError(),
            .raw => try helper.scanTextResultRow(t.value.raw, dest),
        }
    }

    pub fn scanAlloc(t: *const TextResultRow, allocator: std.mem.Allocator) ![]?[]const u8 {
        const record = try allocator.alloc(?[]const u8, t.result_set.col_defs.len);
        try t.scan(record);
        return record;
    }

    pub fn deinit(text_result_set: *const TextResultRow, allocator: std.mem.Allocator) void {
        text_result_set.packet.deinit(allocator);
    }
};

pub const BinaryResultRow = struct {
    result_set: *const ResultSet(BinaryResultRow),
    packet: Packet,
    value: union(enum) {
        err: ErrorPacket,
        eof: EofPacket,
        raw: []const u8,
    },

    const Options = struct {};

    // dest: pointer to a struct
    pub fn scan(b: *const BinaryResultRow, dest: anytype) !void {
        switch (b.value) {
            .err => |err| return err.asError(),
            .eof => |eof| return eof.asError(),
            .raw => |raw| helper.scanBinResultRow(dest, raw, b.result_set.col_defs),
        }
    }

    // returns a pointer to allocated struct object, caller must remember to call destroy on the object after use
    pub fn scanAlloc(b: *const BinaryResultRow, comptime S: type, allocator: std.mem.Allocator) !*S {
        const s = try allocator.create(S);
        try b.scan(s);
        return s;
    }

    pub fn deinit(text_result_set: *const BinaryResultRow, allocator: std.mem.Allocator) void {
        text_result_set.packet.deinit(allocator);
    }
};

pub const PrepareResult = struct {
    const Value = union(enum) {
        ok: PreparedStatement,
        err: ErrorPacket,
    };

    packet: Packet,
    value: Value,

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
    // TODO: use const instead
    prep_ok: PrepareOk,
    packets: []Packet,
    params: []ColumnDefinition41, // parameters that would be passed when executing the query
    res_cols: []ColumnDefinition41, // columns that would be returned when executing the query

    pub fn initFromPacket(resp_packet: *const Packet, conn: *Conn, allocator: std.mem.Allocator) !PreparedStatement {
        const prep_ok = PrepareOk.initFromPacket(resp_packet, conn.client_capabilities);
        var prep_stmt: PreparedStatement = .{ .prep_ok = prep_ok, .packets = &.{}, .params = &.{}, .res_cols = &.{} };
        errdefer prep_stmt.deinit(allocator);

        prep_stmt.packets = try allocator.alloc(Packet, prep_ok.num_params + prep_ok.num_columns);
        @memset(prep_stmt.packets, Packet.safe_deinit());

        prep_stmt.params = try allocator.alloc(ColumnDefinition41, prep_ok.num_params);
        prep_stmt.res_cols = try allocator.alloc(ColumnDefinition41, prep_ok.num_columns);

        if (prep_ok.num_params > 0) {
            for (prep_stmt.packets[0..prep_ok.num_params], prep_stmt.params) |*packet, *param| {
                packet.* = try conn.readPacket(allocator);
                param.* = ColumnDefinition41.initFromPacket(packet);
            }
            try discardEofPacket(conn, allocator);
        }

        if (prep_ok.num_columns > 0) {
            for (prep_stmt.packets[prep_ok.num_params..], prep_stmt.res_cols) |*packet, *res_col| {
                packet.* = try conn.readPacket(allocator);
                res_col.* = ColumnDefinition41.initFromPacket(packet);
            }
            try discardEofPacket(conn, allocator);
        }

        return prep_stmt;
    }

    pub fn deinit(prep_stmt: *const PreparedStatement, allocator: std.mem.Allocator) void {
        allocator.free(prep_stmt.params);
        allocator.free(prep_stmt.res_cols);
        for (prep_stmt.packets) |packet| {
            packet.deinit(allocator);
        }
        allocator.free(prep_stmt.packets);
    }
};

fn discardEofPacket(conn: *Conn, allocator: std.mem.Allocator) !void {
    const eof_packet = try conn.readPacket(allocator);
    defer eof_packet.deinit(allocator);
    std.debug.assert(eof_packet.payload[0] == constants.EOF);
}
