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
