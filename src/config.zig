const std = @import("std");

pub const Config = struct {
    address: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3306),
    password: []const u8 = "",
    reject_read_only: bool = false,
    allow_old_password: bool = false,

    // TODO: Add TLS Config
    tls: bool = false,
    allow_fallback_to_plaintext: bool = false,
};
