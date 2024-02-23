const std = @import("std");
const Config = @import("./config.zig").Config;
const protocol = @import("./protocol.zig");
const Conn = @import("./conn.zig").Conn;
const result = @import("./result.zig");

// TODO: Pool
// pub const Pool = struct {
//     config: Config,
//     conn: Conn,
//
//     pub fn init(config: Config) Pool {
//         return .{
//             .config = config,
//             .conn = .{},
//         };
//     }
//
//     // TODO:
// };
