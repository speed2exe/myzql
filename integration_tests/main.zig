pub const conn = @import("./conn.zig");
pub const pool = @import("./pool.zig");
test {
    // not sure if it still works
    @import("std").testing.refAllDecls(@This());
}
