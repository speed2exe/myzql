const std = @import("std");

pub const Packet = struct {
    sequence_id: u8,
    payload: []u8,

    pub fn initFromReader(allocator: std.mem.Allocator, std_io_reader: anytype) !Packet {
        const header = try std_io_reader.readBytesNoEof(4);
        const length = @as(u32, header[0]) | @as(u32, header[1]) << 8 | @as(u32, header[2]) << 16;
        const sequence_id = header[3];

        var payload = try allocator.alloc(u8, length);
        const n = try std_io_reader.readAll(payload);
        if (n != length) {
            std.log.err("expected {d} bytes, got {d}\n", .{ length, n });
            return error.MalformedPacket;
        }
        return .{
            .sequence_id = sequence_id,
            .payload = payload,
        };
    }

    pub fn deinit(packet: Packet, allocator: std.mem.Allocator) void {
        allocator.free(packet.payload);
    }
};
