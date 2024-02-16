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
        if (p.pos == 0 and p.len == p.buf.len) {
            p.should_double_buf = true;
        }
    }

    // ensure that the buffer has at least req_n bytes for reading
    fn expandBufIfNeeded(p: *PacketReader, req_n: usize) !void {
        if (p.buf.len - p.pos >= req_n) {
            return;
        }

        if (p.pos > 0) {
            // move remaining data to the beginning of the buffer
            const n_remain = p.len - p.pos;
            utils.memMove(p.buf, p.buf[p.pos..p.len]);
            p.pos = 0;
            p.len = n_remain;
            // check again if the buffer is large enough
            if (p.buf.len - p.pos >= req_n) {
                return;
            }
        }

        const new_len = blk: {
            var current_len = utils.nextPowerOf2(@truncate(req_n));
            if (p.should_double_buf) {
                current_len *= 2;
                p.should_double_buf = false;
            }
            break :blk current_len;
        };

        // try resize
        if (p.allocator.resize(p.buf, new_len)) {
            p.buf = p.buf[0..new_len];
            return;
        }

        // if resize failed, try to allocate a new buffer
        const new_buf = try p.allocator.alloc(u8, new_len);
        utils.memMove(new_buf, p.buf[p.pos..p.len]);
        p.allocator.free(p.buf);

        p.buf = new_buf;
    }
};
