const std = @import("std");
const Packet = @import("./packet.zig").Packet;

pub const PacketReader = struct {
    payload: []const u8,
    pos: usize,

    pub fn initFromPacket(packet: *const Packet) PacketReader {
        return .{ .payload = packet.payload, .pos = 0 };
    }

    pub fn initFromPayload(payload: []const u8) PacketReader {
        return .{ .payload = payload, .pos = 0 };
    }

    pub fn peek(packet_reader: *const PacketReader) ?u8 {
        std.debug.assert(packet_reader.payload.len >= packet_reader.pos);
        if (packet_reader.payload.len == packet_reader.pos) {
            return null;
        }
        return packet_reader.payload[packet_reader.pos];
    }

    pub fn forward_one(packet_reader: *PacketReader) void {
        std.debug.assert(packet_reader.payload.len > packet_reader.pos);
        packet_reader.pos += 1;
    }

    pub fn readFixed(packet_reader: *PacketReader, comptime n: usize) *const [n]u8 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..n];
        packet_reader.pos += n;
        return bytes;
    }

    fn readFixedRuntime(packet_reader: *PacketReader, n: usize) []const u8 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..n];
        packet_reader.pos += n;
        return bytes;
    }

    pub fn readByte(packet_reader: *PacketReader) u8 {
        const byte = packet_reader.payload[packet_reader.pos];
        packet_reader.pos += 1;
        return byte;
    }

    pub fn readUInt16(packet_reader: *PacketReader) u16 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..2];
        packet_reader.pos += 2;
        return std.mem.readIntLittle(u16, bytes);
    }

    fn readUInt24(packet_reader: *PacketReader) u24 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..3];
        packet_reader.pos += 3;
        return std.mem.readIntLittle(u24, bytes);
    }

    pub fn readUInt32(packet_reader: *PacketReader) u32 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..4];
        packet_reader.pos += 4;
        return std.mem.readIntLittle(u32, bytes);
    }

    fn readUInt64(packet_reader: *PacketReader) u64 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..8];
        packet_reader.pos += 8;
        return std.mem.readIntLittle(u64, bytes);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_eof
    pub fn readRestOfPacketString(packet_reader: *PacketReader) []const u8 {
        const bytes = packet_reader.payload[packet_reader.pos..];
        packet_reader.pos += bytes.len;
        return bytes;
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html#sect_protocol_basic_dt_int_le
    // max possible value is 2^64 - 1, so return type is u64
    pub fn readLengthEncodedInteger(packet_reader: *PacketReader) u64 {
        const first_byte = packet_reader.readByte();
        switch (first_byte) {
            0xFC => return packet_reader.readUInt16(),
            0xFD => return packet_reader.readUInt24(),
            0xFE => return packet_reader.readUInt64(),
            else => return first_byte,
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_le
    pub fn readLengthEncodedString(packet_reader: *PacketReader) []const u8 {
        const length = packet_reader.readLengthEncodedInteger();
        return packet_reader.readFixedRuntime(@as(usize, length));
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_null
    pub fn readNullTerminatedString(packet_reader: *PacketReader) [:0]const u8 {
        const start = packet_reader.pos;
        const i = std.mem.indexOfScalarPos(u8, packet_reader.payload, start, 0) orelse {
            std.log.warn("null terminated string not found\n, pos: {any}, payload: {any}", .{
                packet_reader.pos,
                packet_reader.payload,
            });
            unreachable;
        };

        const res: [:0]const u8 = @ptrCast(packet_reader.payload[packet_reader.pos..i]);
        packet_reader.pos = i + 1;
        return res;
    }

    pub fn finished(packet_reader: *PacketReader) bool {
        return packet_reader.pos == packet_reader.payload.len;
    }
};
