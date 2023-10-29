const std = @import("std");

const BUFFER_SIZE = 4096;

pub const Reader = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,
    stream: std.net.Stream,

    // read all behavior
    pub fn read(r: *Reader, buffer: []u8) !void {
        var already_read: usize = 0;
        while (buffer.len > already_read) {
            if (r.empty()) {
                try r.fill();
            }
            const n = copy(buffer[already_read..], r.buf[r.pos..r.len]);
            r.pos += n;
            already_read += n;
        }
    }

    inline fn fill(s: *Reader) !void {
        s.len = try s.stream.read(&s.buf);
        if (s.len == 0) {
            return error.UnexpectedEndOfStream;
        }
        s.pos = 0;
    }

    inline fn empty(s: *Reader) bool {
        return s.pos == s.len;
    }
};

pub fn reader(stream: std.net.Stream) Reader {
    return .{ .stream = stream };
}

pub const Writer = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    stream: std.net.Stream,

    // write all behavior
    pub fn write(w: *Writer, buffer: []const u8) !void {
        var already_written: usize = 0;
        while (buffer.len > already_written) {
            if (w.full()) {
                try w.flush();
            }
            const n = copy(w.buf[w.len..], buffer[already_written..]);
            w.len += n;
            already_written += n;
        }
    }

    // if the buffer is full
    inline fn full(w: *Writer) bool {
        return w.len == w.buf.len;
    }

    // how much space is left in the buffer before it is full
    inline fn available(w: *Writer) usize {
        return w.buf.len - w.len;
    }

    // flush the buffer to the stream
    pub inline fn flush(w: *Writer) !void {
        try w.stream.writeAll(w.buf[0..w.len]);
        w.len = 0;
    }

    // copy the buffer to the writer's buffer
    // assert that there is enough space in the buffer
    // this will not flush the buffer to the stream
    pub fn writeToBuffer(w: *Writer, source: []const u8) !void {
        // ensure we have enough space to fill the buffer
        if (source.len > w.available()) {
            std.log.warn(
                "not enough space in buffer, required: {}, available: {}",
                .{ source.len, w.available() },
            );
            return error.BufferNotEnoughSpace;
        }

        const len_after_write = w.len + source.len;
        @memcpy(w.buf[w.len..len_after_write], source);
        w.len = len_after_write;
    }
};

// just a convenience wrapper around Writer
// for payload with size smaller than 4096 - 4
// TODO: growable buffer aside from writer
pub const SmallPacketWriter = struct {
    writer: *Writer,

    pub fn init(w: *Writer, seq_id: u8) SmallPacketWriter {
        std.debug.assert(w.len == 0);
        w.buf[3] = seq_id;
        w.len = 4;
        return .{ .writer = w };
    }

    pub fn write(p: *SmallPacketWriter, buffer: []const u8) !void {
        try p.writer.writeToBuffer(buffer);
    }

    // after this is called, this writer is no longer usable
    pub fn flush(p: *SmallPacketWriter) !void {
        // write the packet length to first 3 bytes
        const payload_size: u24 = @truncate(p.writer.len - 4);
        std.mem.writeIntLittle(u24, p.writer.buf[0..3], payload_size);
        try p.writer.flush();
    }
};

pub fn writer(stream: std.net.Stream) Writer {
    return .{ .stream = stream };
}

fn copy(dest: []u8, src: []const u8) usize {
    const amount_copied = @min(dest.len, src.len);
    var final_dest = dest[0..amount_copied];
    var final_src = src[0..amount_copied];
    @memcpy(final_dest, final_src);
    return amount_copied;
}

test "copy - same length" {
    const src = "hello";
    var dest = [_]u8{ 0, 0, 0, 0, 0 };

    const n = copy(&dest, src);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, src, &dest);
}

test "copy - src length is longer" {
    const src = "hello_goodbye";
    var dest = [_]u8{ 0, 0, 0, 0, 0 };

    const n = copy(&dest, src);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "hello", &dest);
}

test "copy - dest length is longer" {
    const src = "hello";
    var dest = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    const n = copy(&dest, src);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, "hello", dest[0..n]);
}
