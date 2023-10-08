// zig fmt: off
const std = @import("std");

// MySQL Packet Header
pub const OK:             u8 = 0x00;
pub const EOF:            u8 = 0xFE;
pub const AUTH_SWITCH:    u8 = 0xFE;
pub const AUTH_MORE_DATA: u8 = 0x01;
pub const ERR:            u8 = 0xFF;
pub const HANDSHAKE_V10:  u8 = 0x0A;

// https://dev.mysql.com/doc/dev/mysql-server/latest/mysql__com_8h.html#a1d854e841086925be1883e4d7b4e8cad
pub const SERVER_STATUS_IN_TRANS:             u16 = 1 << 0;
pub const SERVER_STATUS_AUTOCOMMIT:           u16 = 1 << 1;
pub const SERVER_MORE_RESULTS_EXISTS:         u16 = 1 << 2;
pub const SERVER_QUERY_NO_GOOD_INDEX_USED:    u16 = 1 << 3;
pub const SERVER_STATUS_CURSOR_EXISTS:        u16 = 1 << 4;
pub const SERVER_STATUS_LAST_ROW_SENT:        u16 = 1 << 5;
pub const SERVER_STATUS_DB_DROPPED:           u16 = 1 << 6;
pub const SERVER_STATUS_NO_BACKSLASH_ESCAPES: u16 = 1 << 7;
pub const SERVER_QUERY_WAS_SLOW:              u16 = 1 << 8;
pub const SERVER_STATUS_IN_TRANS_READONLY:    u16 = 1 << 9;
pub const SERVER_SESSION_STATE_CHANGED:       u16 = 1 << 10;

// https://dev.mysql.com/doc/dev/mysql-server/latest/group__group__cs__capabilities__flags.html
pub const CLIENT_LONG_PASSWORD:   u32 = 1;
pub const CLIENT_FOUND_ROWS:      u32 = 2;
pub const CLIENT_LONG_FLAG:       u32 = 4;
pub const CLIENT_CONNECT_WITH_DB: u32 = 8;
pub const CLIENT_NO_SCHEMA:       u32 = 16;
pub const CLIENT_COMPRESS:        u32 = 32;
pub const CLIENT_ODBC:            u32 = 64;
pub const CLIENT_LOCAL_FILES:     u32 = 128;
pub const CLIENT_IGNORE_SPACE:    u32 = 256;
pub const CLIENT_PROTOCOL_41:     u32 = 512;
pub const CLIENT_INTERACTIVE:     u32 = 1024;
pub const CLIENT_SSL:             u32 = 2048;
pub const CLIENT_IGNORE_SIGPIPE:  u32 = 4096;
pub const CLIENT_TRANSACTIONS:    u32 = 8192;
pub const CLIENT_RESERVED:        u32 = 16384;

pub const CLIENT_RESERVED2:                      u32 = 32768;
pub const CLIENT_MULTI_STATEMENTS:               u32 = 1 << 16;
pub const CLIENT_MULTI_RESULTS:                  u32 = 1 << 17;
pub const CLIENT_PS_MULTI_RESULTS:               u32 = 1 << 18;
pub const CLIENT_PLUGIN_AUTH:                    u32 = 1 << 19;
pub const CLIENT_CONNECT_ATTRS:                  u32 = 1 << 20;
pub const CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA: u32 = 1 << 21;
pub const CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS:   u32 = 1 << 22;
pub const CLIENT_SESSION_TRACK:                  u32 = 1 << 23;
pub const CLIENT_DEPRECATE_EOF:                  u32 = 1 << 24;
pub const CLIENT_OPTIONAL_RESULTSET_METADATA:    u32 = 1 << 25;
pub const CLIENT_ZSTD_COMPRESSION_ALGORITHM:     u32 = 1 << 26;
pub const CLIENT_QUERY_ATTRIBUTES:               u32 = 1 << 27;
pub const CTOR_AUTHENTICATION:                   u32 = 1 << 28;
pub const CLIENT_CAPABILITY_EXTENSION:           u32 = 1 << 29;
pub const CLIENT_SSL_VERIFY_SERVER_CERT:         u32 = 1 << 30;

pub const MAX_CAPABILITIES: u32 = std.math.maxInt(u32);

// plugin names
pub const mysql_native_password = "mysql_native_password";
pub const sha256_password       = "sha256_password";
pub const caching_sha2_password = "caching_sha2_password";
pub const mysql_clear_password  = "mysql_clear_password";
