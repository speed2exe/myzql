const std = @import("std");
const constants = @import("./constants.zig");
const Collation = @import("./collation.zig").Collation;

pub const Config = struct {
    username: [:0]const u8 = "root",
    address: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3306),
    password: []const u8 = "",
    database: [:0]const u8 = "",
    collation: Collation = Collation.utf8mb4_general_ci,

    // cfgs from Golang driver
    client_found_rows: bool = false, // Return number of matching rows instead of rows changed
    ssl: bool = false,
    multi_statements: bool = false,

    pub fn capability_flags(config: *const Config) u32 {
        // zig fmt: off
        var flags: u32 = constants.CLIENT_PROTOCOL_41
                       | constants.CLIENT_PLUGIN_AUTH
                       | constants.CLIENT_SECURE_CONNECTION
                       | constants.CLIENT_DEPRECATE_EOF
                       // TODO: Support more
                       ;
        // zig fmt: on
        if (config.client_found_rows) {
            flags |= constants.CLIENT_FOUND_ROWS;
        }
        if (config.ssl) {
            flags |= constants.CLIENT_SSL;
        }
        if (config.multi_statements) {
            flags |= constants.CLIENT_MULTI_STATEMENTS;
        }
        if (config.database.len > 0) {
            flags |= constants.CLIENT_CONNECT_WITH_DB;
        }
        return flags;
    }
};
