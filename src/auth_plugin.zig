const std = @import("std");

pub const AuthPlugin = enum {
    unspecified,
    mysql_native_password,
    sha256_password,
    caching_sha2_password,
    mysql_clear_password,
    unknown,

    pub fn fromName(name: []const u8) AuthPlugin {
        if (std.mem.eql(u8, name, "mysql_native_password")) {
            return .mysql_native_password;
        } else if (std.mem.eql(u8, name, "sha256_password")) {
            return .sha256_password;
        } else if (std.mem.eql(u8, name, "caching_sha2_password")) {
            return .caching_sha2_password;
        } else if (std.mem.eql(u8, name, "mysql_clear_password")) {
            return .mysql_clear_password;
        } else {
            return .unknown;
        }
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_caching_sha2_authentication_exchanges.html
// https://mariadb.com/kb/en/caching_sha2_password-authentication-plugin/
pub const caching_sha2_password_public_key_response = 0x01;
pub const caching_sha2_password_public_key_request = 0x02;
pub const caching_sha2_password_fast_auth_success = 0x03;
pub const caching_sha2_password_full_authentication_start = 0x04;
