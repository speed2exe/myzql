const myzql = @import("myzql");
const Config = myzql.config.Config;

pub const test_config: Config = .{
    .password = "password",
};

pub const test_config_with_db: Config = .{
    .password = "password",
    .database = "mysql",
};

pub const test_connection_string: []const u8 = "mysql://root:password@127.0.0.1:3306/mysql";
