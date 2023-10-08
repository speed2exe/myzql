pub fn FixedBytes(comptime max: usize) type {
    return struct {
        buf: [max]u8 = undefined,
        len: usize = 0,

        pub fn get(self: *const FixedBytes(max)) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn set(self: *FixedBytes(max), s: []const u8) !void {
            if (s.len > max) {
                return error.SourceTooLarge;
            }
            self.len = 0;
            for (s) |c| {
                self.buf[self.len] = c;
                self.len += 1;
            }
        }
    };
}
