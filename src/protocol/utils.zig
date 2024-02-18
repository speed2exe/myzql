const std = @import("std");

pub fn copy(dest: []u8, src: []const u8) usize {
    const amount_copied = @min(dest.len, src.len);
    const final_dest = dest[0..amount_copied];
    const final_src = src[0..amount_copied];
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

// dst.len >= src.len to ensure all data can be moved
pub fn memMove(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len >= src.len);
    for (dst[0..src.len], src) |*d, s| {
        d.* = s;
    }
}

// 1 -> 1
// 2 -> 2
// 3 -> 4
// 4 -> 4
// 5 -> 8
// 6 -> 8
// ...
pub fn nextPowerOf2(n: u32) u32 {
    std.debug.assert(n > 0);
    var x = n - 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return x + 1;
}
