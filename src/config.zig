const std = @import("std");
const constants = @import("./constants.zig");

/// Configuration for a MySQL/MariaDB connection.
pub const Config = struct {
    /// MySQL username. Default: "root"
    username: [:0]const u8 = "root",
    /// Server address. Default: 127.0.0.1:3306 (IPv4)
    address: Address = .{ .ip = std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") catch unreachable },
    /// MySQL password. Default: ""
    password: []const u8 = "",
    /// Default database to use. Default: ""
    database: [:0]const u8 = "",
    collation: u8 = constants.utf8mb4_general_ci,

    /// Return number of matching rows instead of rows changed. Default: false
    client_found_rows: bool = false,
    /// Enable SSL. Default: false
    ssl: bool = false,
    /// Allow multiple statements in a single query. Default: false
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

pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    unix: std.Io.net.UnixAddress,
};
