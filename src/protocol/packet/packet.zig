const std = @import("std");
const constants = @import("../constants.zig");
const PacketReader = @import("./packet_reader.zig").PacketReader;
const ErrorPacket = @import("./generic_response.zig").ErrorPacket;
const OkPacket = @import("./generic_response.zig").OkPacket;
const EofPacket = @import("./generic_response.zig").EofPacket;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html#sect_protocol_basic_packets_packet
pub const Packet = struct {
    payload_length: u24,
    sequence_id: u8,
    payload: []const u8,

    pub fn initFromReader(allocator: std.mem.Allocator, std_io_reader: anytype) !Packet {
        const payload_length = try std_io_reader.readIntLittle(u24);
        const sequence_id = try std_io_reader.readByte();
        var payload = try allocator.alloc(u8, @as(usize, payload_length));
        const n = try std_io_reader.readAll(payload);
        if (n != payload_length) {
            std.log.err("expected {d} bytes, got {d}\n", .{ payload_length, n });
            return error.ExpectedMorePayload;
        }
        return .{
            .payload_length = payload_length,
            .sequence_id = sequence_id,
            .payload = payload,
        };
    }

    pub fn deinit(packet: Packet, allocator: std.mem.Allocator) void {
        allocator.free(packet.payload);
    }

    pub fn realize(packet: Packet, capabilities: u32, comptime is_first_packet: bool) PacketRealized {
        const first_byte = packet.payload[0];
        return switch (first_byte) {
            constants.OK => .{ .ok_packet = OkPacket.initFromPacket(packet, capabilities) },
            constants.ERR => .{ .error_packet = ErrorPacket.initFromPacket(is_first_packet, packet, capabilities) },
            constants.EOF => .{ .eof_packet = EofPacket.initFromPacket(packet, capabilities) },
            constants.HANDSHAKE_V10 => .{ .handshake_v10 = HandshakeV10.initFromPacket(packet, capabilities) },
            else => |x| {
                std.log.err("unexpected packet type: {any}\n", .{x});
                unreachable;
            },
        };
    }
};

pub const PacketRealized = union(enum) {
    error_packet: ErrorPacket,
    ok_packet: OkPacket,
    eof_packet: EofPacket,
    handshake_v10: HandshakeV10,
};
