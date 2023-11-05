const std = @import("std");

// This is a fixed-size byte array to avoid heap allocation.
pub fn FixedBytes(comptime max: usize) type {
    return struct {
        buf: [max]u8 = undefined,
        len: usize = 0,

        pub fn get(self: *const FixedBytes(max)) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *FixedBytes(max), src: []const u8) void {
            std.debug.assert(src.len <= max);
            var dest = self.buf[0..src.len];
            @memcpy(dest, src);
        }
    };
}
