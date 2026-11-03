const std = @import("std");
const utils = @import("./utils.zig");
const Transport = @import("../transport.zig").Transport;

pub const PacketWriter = struct {
    allocator: std.mem.Allocator,
    transport: *Transport,
    buf: []u8,
    pos: usize, // buf[0..pos]: buffer is written but not flushed

    pub fn init(allocator: std.mem.Allocator, transport: *Transport) PacketWriter {
        return .{
            .allocator = allocator,
            .transport = transport,
            .buf = &.{},
            .pos = 0,
        };
    }

    pub fn deinit(w: *const PacketWriter) void {
        w.allocator.free(w.buf);
    }

    // invalidates all previous writes
    pub fn reset(w: *PacketWriter) void {
        w.pos = 0;
    }

    pub fn write(w: *PacketWriter, src: []const u8) !void {
        try w.expandIfNeeded(src.len);
        const n = utils.copy(w.buf[w.pos..], src);
        std.debug.assert(n == src.len);
        w.pos += n;
    }

    // increase the length of the buffer as if it was written to
    fn skip(w: *PacketWriter, n: usize) !void {
        try w.expandIfNeeded(n);
        w.pos += n;
    }

    // increase the length of the buffer as if it was written to
    // returns a slice of the buffer that can be written to
    fn advance(w: *PacketWriter, n: usize) ![]u8 {
        try w.expandIfNeeded(n);
        const res = w.buf[w.pos .. w.pos + n];
        w.pos += n;
        return res;
    }

    fn advanceComptime(w: *PacketWriter, comptime n: usize) !*[n]u8 {
        try w.expandIfNeeded(n);
        const res = w.buf[w.pos..][0..n];
        w.pos += n;
        return res;
    }

    // flush the buffer to the transport, splitting payloads larger than
    // 0xFFFFFF into multiple wire packets (each continuation fragment gets
    // the next sequence id, and a payload that is an exact multiple of
    // 0xFFFFFF is terminated with an extra empty packet, per the protocol).
    pub inline fn flush(p: *PacketWriter, io: std.Io) !void {
        if (p.pos == 0) return;

        // buf[0..pos] was built by writeBytesAsPacket/writePacketInner:
        // buf[0..3] is a placeholder length, buf[3] is the first sequence id,
        // buf[4..pos] is the payload.
        const payload = p.buf[4..p.pos];
        var seq = p.buf[3];
        var off: usize = 0;
        while (true) {
            const chunk = @min(payload.len - off, 0xFFFFFF);
            var hdr: [4]u8 = undefined;
            std.mem.writeInt(u24, hdr[0..3], @intCast(chunk), .little);
            hdr[3] = seq;
            try p.transport.writeAll(io, &hdr);
            if (chunk > 0) try p.transport.writeAll(io, payload[off .. off + chunk]);
            off += chunk;
            seq +%= 1;
            if (chunk < 0xFFFFFF) break;
        }

        p.pos = 0;
    }

    pub fn writeBytesAsPacket(p: *PacketWriter, sequence_id: u8, buffer: []const u8) !void {
        // the real length is computed by flush(), which fragments payloads
        // larger than 0xFFFFFF; only the sequence id is stored in the header
        try p.skip(4);
        p.buf[p.pos - 1] = sequence_id;
        try p.write(buffer);
    }

    pub fn writePacket(p: *PacketWriter, sequence_id: u8, packet: anytype) !void {
        try p.writePacketInner(false, sequence_id, packet, {});
    }

    pub fn writePacketWithParams(p: *PacketWriter, sequence_id: u8, packet: anytype, params: anytype) !void {
        try p.writePacketInner(true, sequence_id, packet, params);
    }

    fn writePacketInner(
        p: *PacketWriter,
        comptime has_params: bool,
        sequence_id: u8,
        packet: anytype,
        params: anytype,
    ) !void {
        const start = p.pos;
        try p.skip(4);
        // we need to write the payload length and sequence id later
        // after the packet is written
        // [0..3]               [4]         [......]
        // ^u24 payload_length  ^u8 seq_id  ^payload

        if (has_params) {
            try packet.writeWithParams(p, params);
        } else {
            try packet.write(p);
        }

        // the real payload length is computed by flush(); see writeBytesAsPacket
        p.buf[start + 3] = sequence_id;
    }

    pub fn writeInt(p: *PacketWriter, comptime Int: type, int: Int) !void {
        const bytes = try p.advanceComptime(@divExact(@typeInfo(Int).int.bits, 8));
        std.mem.writeInt(Int, bytes, int, .little);
    }

    pub fn writeNullTerminatedString(p: *PacketWriter, v: [:0]const u8) !void {
        try p.write(v[0 .. v.len + 1]);
    }

    pub fn writeFillers(p: *PacketWriter, comptime n: comptime_int) !void {
        _ = try p.advance(n);
    }

    pub fn writeLengthEncodedString(p: *PacketWriter, s: []const u8) !void {
        try p.writeLengthEncodedInteger(s.len);
        try p.write(s);
    }

    pub fn writeLengthEncodedInteger(p: *PacketWriter, v: u64) !void {
        if (v < 251) {
            try p.writeInt(u8, @intCast(v));
        } else if (v < 1 << 16) {
            try p.writeInt(u8, 0xFC);
            try p.writeInt(u16, @intCast(v));
        } else if (v < 1 << 24) {
            try p.writeInt(u8, 0xFD);
            try p.writeInt(u24, @intCast(v));
        } else if (v < 1 << 64) {
            try p.writeInt(u8, 0xFE);
            try p.writeInt(u64, v);
        } else {
            return error.InvalidLengthEncodedInteger;
        }
    }

    // invalidates all futures writes returned by `advance`
    fn expandIfNeeded(w: *PacketWriter, req_n: usize) !void {
        if (req_n <= w.buf.len - w.pos) {
            return;
        }

        const target_len = w.buf.len + req_n;
        const new_len = utils.nextPowerOf2(@intCast(target_len));

        // try resize
        if (w.allocator.resize(w.buf, new_len)) {
            w.buf.len = new_len;
            return;
        }

        // if resize failed, try to allocate a new buffer
        const new_buf = try w.allocator.alloc(u8, new_len);
        @memcpy(new_buf[0..w.buf.len], w.buf);
        w.allocator.free(w.buf);
        w.buf = new_buf;
    }
};
