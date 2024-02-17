const std = @import("std");
const constants = @import("../constants.zig");
const ErrorPacket = @import("./generic_response.zig").ErrorPacket;
// const PacketReader = @import("./packet_reader.zig").PacketReader;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html#sect_protocol_basic_packets_packet
pub const Packet = struct {
    sequence_id: u8,
    payload: []const u8,

    pub fn init(sequence_id: u8, payload: []const u8) Packet {
        return .{ .sequence_id = sequence_id, .payload = payload };
    }

    pub fn asError(packet: *const Packet) error{ UnexpectedPacket, ErrorPacket } {
        if (packet.payload[0] == constants.ERR) {
            return ErrorPacket.init(packet).asError();
        }
        std.log.warn("unexpected packet: {any}", .{packet});
        return error.UnexpectedPacket;
    }

    pub fn reader(packet: *const Packet) PayloadReader {
        return PayloadReader.init(packet.payload);
    }

    pub fn cloneAlloc(packet: *const Packet, allocator: std.mem.Allocator) !Packet {
        const payload_copy = try allocator.alloc(u8, packet.payload.len);
        return .{ .sequence_id = packet.sequence_id, .payload = payload_copy };
    }

    pub fn deinit(packet: *const Packet, allocator: std.mem.Allocator) void {
        allocator.free(packet.payload);
    }
};

pub const PayloadReader = struct {
    payload: []const u8,
    pos: usize,

    fn init(payload: []const u8) PayloadReader {
        return .{ .payload = payload, .pos = 0 };
    }

    pub fn peek(p: *const PayloadReader) ?u8 {
        std.debug.assert(p.pos <= p.payload.len);
        if (p.pos == p.payload.len) {
            return null;
        }
        return p.payload[p.pos];
    }

    pub fn readInt(p: *PayloadReader, Int: type) Int {
        const bytes = p.readRefComptime(@divExact(@typeInfo(Int).Int.bits, 8));
        return std.mem.readInt(Int, bytes, .little);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_eof
    pub fn readRefRemaining(p: *PayloadReader) []const u8 {
        return p.readRefRuntime(p.payload.len - p.pos);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html#sect_protocol_basic_dt_int_le
    // max possible value is 2^64 - 1, so return type is u64
    pub fn readLengthEncodedInteger(p: *PayloadReader) u64 {
        const first_byte = p.readInt(u8);
        switch (first_byte) {
            0xFC => return p.readInt(u16),
            0xFD => return p.readInt(u24),
            0xFE => return p.readInt(u64),
            else => return first_byte,
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_le
    pub fn readLengthEncodedString(p: *PayloadReader) []const u8 {
        const length = p.readLengthEncodedInteger();
        return p.readRefRuntime(@as(usize, length));
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_null
    pub fn readNullTerminatedString(p: *PayloadReader) [:0]const u8 {
        const i = std.mem.indexOfScalarPos(u8, p.payload, p.pos, 0) orelse {
            std.log.warn(
                "null terminated string not found\n, pos: {any}, payload: {any}",
                .{ p.pos, p.payload },
            );
            unreachable;
        };

        const bytes = p.payload[p.pos..i];
        p.pos = i + 1;
        return @ptrCast(bytes);
    }

    pub fn skipComptime(p: *PayloadReader, comptime n: usize) void {
        std.debug.assert(p.pos + n <= p.payload.len);
        p.pos += n;
    }

    pub fn finished(p: *PayloadReader) bool {
        return p.payload.len == p.pos;
    }

    pub fn remained(p: *PayloadReader) usize {
        return p.payload.len - p.pos;
    }

    pub fn readRefComptime(p: *PayloadReader, comptime n: usize) *const [n]u8 {
        std.debug.assert(p.pos + n <= p.payload.len);
        const bytes = p.payload[p.pos..][0..n];
        p.pos += n;
        return bytes;
    }

    pub fn readRefRuntime(p: *PayloadReader, n: usize) []const u8 {
        std.debug.assert(p.pos + n <= p.payload.len);
        const bytes = p.payload[p.pos .. p.pos + n];
        p.pos += n;
        return bytes;
    }
};
