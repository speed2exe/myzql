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

pub fn QueryResult(comptime T: type) type {
    return struct {
        const Value = union(enum) {
            ok: *const OkPacket,
            err: *const ErrorPacket,
            rows: ResultSet(T),
        };
        packet: Packet,
        value: Value,

        pub fn init(conn: *Conn, allocator: std.mem.Allocator) !QueryResult(T) {
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
            @memset(col_packets, Packet.safe_deinit());
            const col_defs = try allocator.alloc(ColumnDefinition41, column_count);

            for (col_packets, col_defs) |*pac, *def| {
                pac.* = try conn.readPacket(allocator);
                def.* = ColumnDefinition41.initFromPacket(pac);
            }

            try discardEofPacket(conn, allocator);

            return .{ .conn = conn, .col_packets = col_packets, .col_defs = col_defs };
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
        try helper.scanTextResultRow(dest, t.raw);
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
        try helper.scanBinResultRow(dest, b.raw, b.col_defs);
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
            eof: EofPacket,

            //https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query_response_text_resultset_row.html
            data: T,
        };
        packet: Packet,
        value: Value,

        fn init(conn: *Conn, allocator: std.mem.Allocator, col_defs: []const ColumnDefinition41) !ResultRow(T) {
            const packet = try conn.readPacket(allocator);
            return .{
                .packet = packet,
                .value = switch (packet.payload[0]) {
                    constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &packet, conn.client_capabilities) },
                    constants.EOF => .{ .eof = EofPacket.initFromPacket(&packet, conn.client_capabilities) },
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
                        .eof => |eof| return eof.asError(),
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
