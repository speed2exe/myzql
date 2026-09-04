pub const conn = @import("./conn.zig");
pub const pool = @import("./pool.zig");
pub const auth_switch = @import("./auth_switch.zig");
test {
    // not sure if it still works
    @import("std").testing.refAllDecls(@This());
}
