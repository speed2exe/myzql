const myzql = @import("myzql");
const Config = myzql.config.Config;

pub const test_config: Config = .{
    .password = "password",
};

pub const test_config_with_db: Config = .{
    .password = "password",
    .database = "mysql",
};
