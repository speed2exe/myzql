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
const PacketReader = @import("./protocol/packet_reader.zig").PacketReader;

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

    pub fn next(t: *TextResultSet, allocator: std.mem.Allocator) !?TextResultRow {
        const packet = try t.conn.readPacket(allocator);
        errdefer packet.deinit(allocator);

        return switch (packet.payload[0]) {
            constants.EOF => {
                packet.deinit(allocator);
                return null;
            },
            constants.ERR => return packet.asError(t.conn.client_capabilities),
            else => return .{
                .packet = packet,
                .text_result_set = t,
            },
        };
    }

    pub const TextResultRow = struct {
        packet: Packet,
        text_result_set: *const TextResultSet,

        pub fn scan(r: *const TextResultRow, dest: []?[]const u8) void {
            std.debug.assert(r.text_result_set.column_definitions.len == dest.len);

            var packet_reader = PacketReader.initFromPacket(&r.packet);
            for (dest) |*d| {
                d.* = blk: {
                    const first_byte = blk2: {
                        const byte_opt = packet_reader.peek();
                        std.debug.assert(byte_opt != null);
                        break :blk2 byte_opt.?;
                    };
                    if (first_byte == constants.TEXT_RESULT_ROW_NULL) {
                        packet_reader.forward_one();
                        break :blk null;
                    }
                    break :blk packet_reader.readLengthEncodedString();
                };
            }
        }

        pub fn deinit(text_result_set: *const TextResultRow, allocator: std.mem.Allocator) void {
            text_result_set.packet.deinit(allocator);
        }
    };
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
            constants.OK => OkPacket.initFromPacket(&q.packet, q.conn.client_capabilities),
            constants.ERR => ErrorPacket.initFromPacket(false, &q.packet, q.conn.client_capabilities).asError(),
            else => error.RowsReturnedNotConsumed,
        };
    }
};
