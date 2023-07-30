pub const Config = struct {
    password: []const u8,
    reject_read_only: bool = false,

    // TODO: Add TLS Config
    tls: bool = false,
    allow_fallback_to_plaintext: bool = false,
};
