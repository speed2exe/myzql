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

pub fn QueryResult(comptime ResultRowType: type) type {
    return struct {
        packet: Packet,
        value: union(enum) {
            ok: OkPacket,
            err: ErrorPacket,
            rows: ResultSet(ResultRowType),
        },

        pub fn deinit(q: *const QueryResult(ResultRowType), allocator: std.mem.Allocator) void {
            q.packet.deinit(allocator);
            switch (q.value) {
                .rows => |rows| rows.deinit(allocator),
                else => {},
            }
        }
    };
}

pub fn ResultSet(comptime ResultRowType: type) type {
    return struct {
        conn: *Conn,
        column_packets: []Packet,
        column_definitions: []ColumnDefinition41,

        pub fn init(allocator: std.mem.Allocator, conn: *Conn, column_count: u64) !ResultSet(ResultRowType) {
            var t: ResultSet(ResultRowType) = .{ .conn = conn, .column_packets = &.{}, .column_definitions = &.{} };
            errdefer t.deinit(allocator);

            t.column_packets = try allocator.alloc(Packet, column_count);
            @memset(t.column_packets, Packet.safe_deinit());
            t.column_definitions = try allocator.alloc(ColumnDefinition41, column_count);

            for (t.column_packets, t.column_definitions) |*pac, *def| {
                pac.* = try conn.readPacket(allocator);
                def.* = ColumnDefinition41.initFromPacket(pac);
            }

            const eof_packet = try conn.readPacket(allocator);
            defer eof_packet.deinit(allocator);
            std.debug.assert(eof_packet.payload[0] == constants.EOF);

            t.conn = conn;
            return t;
        }

        fn deinit(t: *const ResultSet(ResultRowType), allocator: std.mem.Allocator) void {
            for (t.column_packets) |packet| {
                packet.deinit(allocator);
            }
            allocator.free(t.column_packets);
            allocator.free(t.column_definitions);
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
            return .{ .text_result_set = t };
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
        std.debug.assert(dest.len == t.result_set.column_definitions.len);
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

pub const BinaryResultRow = struct {
    result_set: *const ResultSet(BinaryResultRow),
    packet: Packet,
    value: union(enum) {
        err: ErrorPacket,
        eof: EofPacket,
        raw: []const u8,
    },

    const Options = struct {};

    pub fn scanStruct(comptime T: type, t: *const BinaryResultRow, dest: ?*const T, options: Options) !void {
        switch (t.value) {
            .err => |err| return err.asError(),
            .eof => |eof| return eof.asError(),
            .raw => try helper.scanTextBinaryRow(T, t.value.raw, dest, options),
        }
    }

    pub fn deinit(text_result_set: *const BinaryResultRow, allocator: std.mem.Allocator) void {
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
