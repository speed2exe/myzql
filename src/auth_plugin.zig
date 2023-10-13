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

pub const caching_sha2_password_public_key_request = 0x01;
pub const caching_sha2_password_public_key_response = 0x02;
pub const caching_sha2_password_scramble_success = 0x03;
pub const caching_sha2_password_scramble_failure = 0x04;
