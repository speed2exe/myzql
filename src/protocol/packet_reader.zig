const std = @import("std");
const utils = @import("./utils.zig");
const Packet = @import("./packet.zig");

pub const PacketReader = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    io: std.Io,
    buf: []u8, // internal buffer
    pos: usize, // unread data starts from pos
    len: usize, // unread data ends at len, so unread data is in buf[pos..len]

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) !PacketReader {
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .buf = &.{},
            .pos = 0,
            .len = 0,
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

    // read at least `at_least` bytes from network into the internal buffer
    fn readToBufferAtLeast(p: *PacketReader, at_least: usize) !void {
        try p.expandBufIfNeeded(at_least);
        const n = try p.readAtLeast(at_least);
        if (n == 0) {
            return error.UnexpectedEndOfStream;
        }
        if (n < at_least) {
            return error.ShortRead;
        }

        p.len += n;
        if (n >= p.buf.len / 2) {
            // TODO: should doubles the buffer
        }
    }

    fn readAtLeast(p: *PacketReader, at_least: usize) !usize {
        var total_read: usize = 0;
        while (total_read < at_least) {
            var bufs: [1][]u8 = .{p.buf[p.len + total_read ..]};
            const n = try p.stream.read(p.io, &bufs);
            if (n == 0) break;
            total_read += n;
        }
        return total_read;
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
        const unused = p.buf.len - n_remain;
        if (unused >= req_n) {
            p.moveRemainingDataToBeginning();
            return;
        }

        const new_len = utils.nextPowerOf2(@intCast(req_n + p.buf.len));

        // try resize
        if (p.allocator.resize(p.buf, new_len)) {
            p.buf = p.buf[0..new_len];
            // after resizing, buf wil look like this: [...[valid data][X]]
            if ((p.buf.len - p.len) >= req_n) {
                // if X is large enough, we don't need to move data
                return;
            }
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
