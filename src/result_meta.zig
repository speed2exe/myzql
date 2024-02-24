const std = @import("std");
const protocol = @import("./protocol.zig");
const ColumnDefinition41 = protocol.column_definition.ColumnDefinition41;
const Conn = @import("./conn.zig").Conn;

pub const ResultMeta = struct {
    raw: std.ArrayList(u8),
    col_defs: std.ArrayList(ColumnDefinition41),

    pub fn init(allocator: std.mem.Allocator) ResultMeta {
        return ResultMeta{
            .raw = std.ArrayList(u8).init(allocator),
            .col_defs = std.ArrayList(ColumnDefinition41).init(allocator),
        };
    }

    pub fn deinit(r: *const ResultMeta) void {
        r.raw.deinit();
        r.col_defs.deinit();
    }

    pub inline fn readPutResultColumns(r: *ResultMeta, c: *Conn, n: usize) !void {
        r.raw.clearRetainingCapacity();
        r.col_defs.clearRetainingCapacity();

        const col_defs = try r.col_defs.addManyAsSlice(n);
        for (col_defs) |*col_def| {
            var packet = try c.readPacket();
            const payload_owned = try r.raw.addManyAsSlice(packet.payload.len);
            @memcpy(payload_owned, packet.payload);
            packet.payload = payload_owned;
            col_def.init2(&packet);
        }
    }
};
