const generic_response = @import("./protocol/generic_response.zig");
const Conn = @import("./conn.zig").Conn;
const std = @import("std");

pub const QueryResult = union(enum) {
    ok: generic_response.OkPacket,
    err: generic_response.ErrorPacket,
    rows: TextResultSet,
};

pub const TextResultSet = struct {
    allocator: std.mem.Allocator,
    conn: *Conn,
    column_count: u64,
    // columns: []ColumnDefinition,
    // rows: []Row,

    pub fn init(allocator: std.mem.Allocator, conn: *Conn, column_count: u64) TextResultSet {
        return .{
            .allocator = allocator,
            .conn = conn,
            .column_count = column_count,
        };
    }
};
