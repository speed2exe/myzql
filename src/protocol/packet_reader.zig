const std = @import("std");
const utils = @import("./utils.zig");
const Packet = @import("./packet.zig");
const Transport = @import("../transport.zig").Transport;

pub const PacketReader = struct {
    allocator: std.mem.Allocator,
    transport: *Transport,
    buf: []u8, // internal buffer
    pos: usize, // unread data starts from pos
    len: usize, // unread data ends at len, so unread data is in buf[pos..len]

    pub fn init(allocator: std.mem.Allocator, transport: *Transport) PacketReader {
        return .{
            .allocator = allocator,
            .transport = transport,
            .buf = &.{},
            .pos = 0,
            .len = 0,
        };
    }

    pub fn deinit(p: *const PacketReader) void {
        p.allocator.free(p.buf);
    }

    // invalidates the last packet returned
    pub fn readPacket(p: *PacketReader, io: std.Io) !Packet.Packet {
        if (p.pos == p.len) {
            p.pos = 0;
            p.len = 0;
            try p.readToBufferAtLeast(io, 4);
        } else if (p.len - p.pos < 4) {
            try p.readToBufferAtLeast(io, 4);
        }

        // Packet header
        const payload_length = std.mem.readInt(u24, p.buf[p.pos..][0..3], .little);
        const sequence_id = p.buf[p.pos + 3];
        p.pos += 4;

        { // read more bytes from network if required
            const n_valid_unread = p.len - p.pos;
            if (n_valid_unread < payload_length) {
                try p.readToBufferAtLeast(io, payload_length - n_valid_unread);
            }
        }

        // A payload_length of 0xFFFFFF means the logical packet is split into
        // multiple packets on the wire. Append continuation payloads until one
        // is shorter than 0xFFFFFF; 0 terminates (payload is a multiple of
        // 0xFFFFFF - 1... i.e. 0xFFFFFF - 1 + 0). The first frame's sequence id
        // is reported; the continuation frames' sequence ids are only used to
        // keep the wire in sync and are not exposed to the caller.
        if (payload_length == 0xFFFFFF) {
            // Keep the invariant p.len - p.pos == total: p.pos stays at the
            // start of the first payload so expandBufIfNeeded's move preserves
            // the already-assembled data.
            var total: usize = 0xFFFFFF;
            while (true) {
                // Continuation headers go into a stack temp (not p.buf),
                // otherwise they would land in the middle of the payload.
                var hdr: [4]u8 = undefined;
                var done: usize = 0;
                while (done < 4) {
                    const n = try p.transport.read(io, hdr[done..]);
                    if (n == 0) return error.UnexpectedEndOfStream;
                    done += n;
                }
                const cont_len = std.mem.readInt(u24, hdr[0..3], .little);
                if (cont_len == 0) break;

                try p.expandBufIfNeeded(cont_len);
                const n = try p.readAtLeast(io, cont_len);
                if (n == 0) return error.UnexpectedEndOfStream;
                if (n < cont_len) return error.ShortRead;
                p.len += n;
                total += cont_len;

                if (cont_len < 0xFFFFFF) break;
            }

            const payload = p.buf[p.pos .. p.pos + total];
            p.pos += total;
            return .{
                .sequence_id = sequence_id,
                .payload = payload,
            };
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
    fn readToBufferAtLeast(p: *PacketReader, io: std.Io, at_least: usize) !void {
        try p.expandBufIfNeeded(at_least);
        const n = try p.readAtLeast(io, at_least);
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

    fn readAtLeast(p: *PacketReader, io: std.Io, at_least: usize) !usize {
        var total_read: usize = 0;
        while (total_read < at_least) {
            // Never read more than requested: callers (especially the
            // >16MB reassembly path in readPacket) rely on buf[p.len..] being
            // the exact bytes still missing for the current packet.
            const dest = p.buf[p.len + total_read ..][0 .. at_least - total_read];
            const result = try p.transport.read(io, dest);
            if (result == 0) break;
            total_read += result;
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
            p.buf.len = new_len;
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
