pub const conn = @import("./conn.zig");

test {
    // not sure if it still works
    @import("std").testing.refAllDecls(@This());
}
