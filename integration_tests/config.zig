const std = @import("std");
const myzql = @import("myzql");
const Config = myzql.config.Config;
const build_options = @import("build_options");

pub const test_config: Config = .{
    .password = "password",
};

pub const test_config_with_db: Config = .{
    .password = "password",
    .database = "mysql",
};

pub const test_config_unix: ?Config = if (build_options.unix_socket_path) |path| .{
    .password = "password",
    .address = .{ .unix = std.Io.net.UnixAddress.init(path) catch unreachable },
} else null;
