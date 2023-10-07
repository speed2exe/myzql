const std = @import("std");

const BUFFER_SIZE = 4096;

pub const Reader = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,
    stream: std.net.Stream,

    // read all behavior
    pub fn read(s: *Reader, buffer: []u8) !void {
        var already_read: usize = 0;
        while (buffer.len > already_read) {
            if (s.empty()) {
                try s.fill();
            }
            already_read += copy(buffer[already_read..], s.buf[s.pos..s.len]);
        }
    }

    inline fn fill(s: *Reader) !void {
        s.len = try s.stream.read(&s.buf);
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
    pub fn write(s: *Writer, buffer: []const u8) !void {
        var already_written: usize = 0;
        while (buffer.len > already_written) {
            if (s.full()) {
                try s.flush();
            }
            const n = copy(s.buf[s.len..], buffer[already_written..]);
            s.len += n;
            already_written += n;
        }
    }

    inline fn full(s: *Writer) bool {
        return s.len == s.buf.len;
    }

    pub inline fn flush(s: *Writer) !void {
        try s.stream.writeAll(s.buf[0..s.len]);
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
