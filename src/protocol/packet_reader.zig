const std = @import("std");
const utils = @import("./utils.zig");
const Packet = @import("./packet.zig");

pub const PacketReader = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    buf: []u8,
    pos: usize,
    len: usize,

    // if in one read, the buffer is filled, we should double the buffer size
    should_double_buf: bool,

    pub fn init(stream: std.net.Stream, allocator: std.mem.Allocator) !PacketReader {
        return .{
            .buf = try allocator.alloc(u8, 4),
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
        }

        if (p.len < 4) {
            try p.readAtLeast(4);
        }

        p.pos += 4;
        const payload_length = std.mem.readInt(u24, p.buf[0..3], .little);
        const sequence_id = p.buf[3];

        const n_valid_data = p.len - p.pos;
        if (n_valid_data < payload_length) {
            try p.readAtLeast(payload_length - n_valid_data);
        }

        p.pos += payload_length;
        return .{
            .sequence_id = sequence_id,
            .payload = p.buf[4..],
        };
    }

    fn readAtLeast(p: *PacketReader, at_least: usize) !void {
        try p.expandBufIfNeeded(at_least);

        const n = try p.stream.readAtLeast(p.buf[p.len..], at_least);
        if (n == 0) {
            return error.UnexpectedEndOfStream;
        }
        p.len += n;
        if (p.pos == 0 and p.len == p.buf.len) {
            p.should_double_buf = true;
        }
    }

    // ensure that the buffer has at least req_n bytes for reading
    fn expandBufIfNeeded(p: *PacketReader, req_n: usize) !void {
        if (req_n <= p.len - p.pos) {
            return;
        }

        // move remaining data to the beginning of the buffer
        const remaining = p.len - p.pos;
        @memcpy(p.buf, p.buf[p.pos..p.len]);
        p.pos = 0;
        p.len = remaining;

        const new_len = blk: {
            var current_len = p.buf.len;
            if (p.should_double_buf) {
                current_len *= 2;
                p.should_double_buf = false;
            }
            while (current_len < req_n) {
                current_len *= 2;
            }
            break :blk current_len;
        };

        // try resize
        if (p.allocator.resize(p.buf, new_len)) {
            return;
        }

        // if resize failed, try to allocate a new buffer
        const new_buf = try p.allocator.alloc(u8, new_len);
        @memcpy(new_buf, p.buf);
        p.allocator.free(p.buf);
        p.buf = new_buf;
    }
};
