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
const TextResultSetIter = helper.TextResultSetIter;

pub const QueryResult = struct {
    packet: Packet,
    value: union(enum) {
        ok: OkPacket,
        err: ErrorPacket,
        rows: TextResultSet,
    },

    pub fn deinit(q: *const QueryResult, allocator: std.mem.Allocator) void {
        q.packet.deinit(allocator);
        switch (q.value) {
            .rows => |rows| rows.deinit(allocator),
            else => {},
        }
    }
};

pub const TextResultSet = struct {
    conn: *Conn,
    column_packets: []Packet,
    column_definitions: []ColumnDefinition41,

    pub fn init(allocator: std.mem.Allocator, conn: *Conn, column_count: u64) !TextResultSet {
        var t: TextResultSet = undefined;

        t.column_packets = try allocator.alloc(Packet, column_count);
        errdefer allocator.free(t.column_packets);
        t.column_definitions = try allocator.alloc(ColumnDefinition41, column_count);
        errdefer allocator.free(t.column_definitions);
        for (0..column_count) |i| {
            const packet = try conn.readPacket(allocator);
            errdefer packet.deinit(allocator);
            t.column_packets[i] = packet;
            t.column_definitions[i] = ColumnDefinition41.initFromPacket(&packet);
        }

        const eof_packet = try conn.readPacket(allocator);
        defer eof_packet.deinit(allocator);
        std.debug.assert(eof_packet.payload[0] == constants.EOF);

        t.conn = conn;
        return t;
    }

    fn deinit(t: *const TextResultSet, allocator: std.mem.Allocator) void {
        for (t.column_packets) |packet| {
            packet.deinit(allocator);
        }
        allocator.free(t.column_packets);
        allocator.free(t.column_definitions);
    }

    pub fn readRow(t: *const TextResultSet, allocator: std.mem.Allocator) !TextResultRow {
        const packet = try t.conn.readPacket(allocator);
        return .{
            .text_result_set = t,
            .packet = packet,
            .value = switch (packet.payload[0]) {
                constants.ERR => .{ .err = ErrorPacket.initFromPacket(false, &packet, t.conn.client_capabilities) },
                constants.EOF => .{ .eof = EofPacket.initFromPacket(&packet, t.conn.client_capabilities) },
                else => .{ .raw = packet.payload },
            },
        };
    }

    pub fn iter(t: *const TextResultSet) TextResultSetIter {
        return .{ .text_result_set = t };
    }
};

pub const TextResultRow = struct {
    text_result_set: *const TextResultSet,
    packet: Packet,
    value: union(enum) {
        err: ErrorPacket,
        eof: EofPacket,

        //https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query_response_text_resultset_row.html
        raw: []const u8,
    },

    pub fn scan(t: *const TextResultRow, dest: []?[]const u8) !void {
        switch (t.value) {
            .err => |err| return err.asError(),
            .eof => |eof| return eof.asError(),
            .raw => try helper.scanTextResultRow(t.value.raw, dest),
        }
    }

    pub fn deinit(text_result_set: *const TextResultRow, allocator: std.mem.Allocator) void {
        text_result_set.packet.deinit(allocator);
    }
};

pub const PrepareResult = struct {
    packet: Packet,
    value: union(enum) {
        ok: PrepareOk,
        err: ErrorPacket,
    },

    pub fn deinit(p: *const PrepareResult, allocator: std.mem.Allocator) void {
        p.packet.deinit(allocator);
    }
};

pub const ExecuteResponse = struct {
    packet: Packet,
    conn: *Conn,

    pub fn deinit(e: *const ExecuteResponse, allocator: std.mem.Allocator) void {
        e.packet.deinit(allocator);
    }

    pub fn ok(q: *const ExecuteResponse) !OkPacket {
        return switch (q.packet.payload[0]) {
            constants.OK => OkPacket.initFromPacket(q.packet, q.conn.client_capabilities),
            constants.ERR => ErrorPacket.initFromPacket(false, q.packet, q.conn.client_capabilities).asError(),
            else => error.RowsReturnedNotConsumed,
        };
    }
};