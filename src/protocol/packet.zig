const std = @import("std");
const constants = @import("../constants.zig");
const buffered_stream = @import("../stream_buffered.zig");
const ErrorPacket = @import("./generic_response.zig").ErrorPacket;
const Config = @import("../config.zig").Config;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html#sect_protocol_basic_packets_packet
pub const Packet = struct {
    payload_length: u24,
    sequence_id: u8,
    payload: []const u8,

    // generate a packet safe to deinit with allocator
    pub fn safe_deinit() Packet {
        return .{ .payload_length = undefined, .sequence_id = undefined, .payload = &.{} };
    }

    pub fn initFromReader(allocator: std.mem.Allocator, sbr: *buffered_stream.Reader) !Packet {
        var packet: Packet = undefined;

        packet.payload_length = try readUInt24(sbr);
        packet.sequence_id = try readUInt8(sbr);
        packet.payload = blk: {
            var payload = try allocator.alloc(u8, @as(usize, packet.payload_length));
            try sbr.read(payload);
            break :blk payload;
        };
        return packet;
    }

    pub fn asError(packet: *const Packet, capabilities: u32) error{ UnexpectedPacket, ErrorPacket } {
        if (packet.payload[0] == constants.ERR) {
            return ErrorPacket.initFromPacket(false, packet, capabilities).asError();
        }
        std.log.warn("unexpected packet: {any}", .{packet});
        return error.UnexpectedPacket;
    }

    pub fn deinit(packet: *const Packet, allocator: std.mem.Allocator) void {
        allocator.free(packet.payload);
    }
};

fn readUInt24(reader: *buffered_stream.Reader) !u24 {
    var bytes: [3]u8 = undefined;
    try reader.read(&bytes);
    return std.mem.readInt(u24, &bytes, .little);
}

fn readUInt8(reader: *buffered_stream.Reader) !u8 {
    var bytes: [1]u8 = undefined;
    try reader.read(&bytes);
    return bytes[0];
}
