const std = @import("std");
const utils = @import("./utils.zig");
const Packet = @import("./packet.zig");

pub const PacketReader = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    // valid buffer read from network but yet to consume to create packet:
    // buf[pos..len]
    buf: []u8,
    pos: usize,
    len: usize,

    // if in one read, the buffer is filled, we should double the buffer size
    should_double_buf: bool,

    pub fn init(stream: std.net.Stream, allocator: std.mem.Allocator) !PacketReader {
        return .{
            .buf = &.{},
            .stream = stream,
            .allocator = allocator,
            .pos = 0,
            .len = 0,
            .should_double_buf = false,
        };
    }

    pub fn deinit(p: *const PacketReader) void {
        p.allocator.free(p.buf);
    }

    // invalidates the last packet returned
    pub fn readPacket(p: *PacketReader) !Packet.Packet {
        if (p.pos == p.len) {
            p.pos = 0;
            p.len = 0;
            try p.readToBufferAtLeast(4);
        } else if (p.len - p.pos < 4) {
            try p.readToBufferAtLeast(4);
        }

        // Packet header
        const payload_length = std.mem.readInt(u24, p.buf[p.pos..][0..3], .little);
        const sequence_id = p.buf[3];
        p.pos += 4;

        { // read more bytes from network if required
            const n_valid_unread = p.len - p.pos;
            if (n_valid_unread < payload_length) {
                try p.readToBufferAtLeast(payload_length - n_valid_unread);
            }
        }

        // Packet payload
        const payload = p.buf[p.pos .. p.pos + payload_length];
        p.pos += payload_length;

        return .{
            .sequence_id = sequence_id,
            .payload = payload,
        };
    }

    fn readToBufferAtLeast(p: *PacketReader, at_least: usize) !void {
        try p.expandBufIfNeeded(at_least);
        const n = try p.stream.readAtLeast(p.buf[p.len..], at_least);
        if (n == 0) {
            return error.UnexpectedEndOfStream;
        }

        p.len += n;
        if (n >= p.buf.len / 2) {
            p.should_double_buf = true;
        }
    }

    fn moveRemainingDataToBeginning(p: *PacketReader) void {
        if (p.pos == 0) {
            return;
        }
        const n_remain = p.len - p.pos;
        if (n_remain > p.pos) { // if overlap
            utils.memMove(p.buf, p.buf[p.pos..p.len]);
        } else {
            @memcpy(p.buf[0..n_remain], p.buf[p.pos..p.len]);
        }
        p.pos = 0;
        p.len = n_remain;
    }

    // ensure that the buffer can read extra `req_n` bytes
    fn expandBufIfNeeded(p: *PacketReader, req_n: usize) !void {
        if (p.buf.len - p.len >= req_n) {
            return;
        }

        const n_remain = p.len - p.pos;

        // possible to move remaining data to the beginning of the buffer
        // such that it will be enough?
        if (!p.should_double_buf) {
            // move remaining data to the beginning of the buffer
            const unused = p.buf.len - n_remain;
            if (unused >= req_n) {
                p.moveRemainingDataToBeginning();
                return;
            }
        }

        const new_len = blk: {
            var current = p.buf.len;
            if (p.should_double_buf) {
                current *= 2;
                p.should_double_buf = false;
            }
            break :blk utils.nextPowerOf2(@truncate(req_n + current));
        };

        // try resize
        if (p.allocator.resize(p.buf, new_len)) {
            p.buf = p.buf[0..new_len];
            p.moveRemainingDataToBeginning();
            return;
        }

        // if resize failed, try to allocate a new buffer
        // and copy the remaining data to the new buffer
        const new_buf = try p.allocator.alloc(u8, new_len);
        @memcpy(new_buf[0..n_remain], p.buf[p.pos..p.len]);
        p.allocator.free(p.buf);
        p.buf = new_buf;
        p.pos = 0;
        p.len = n_remain;
    }
};
