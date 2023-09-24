const default_auth_plugin = "mysql_native_password";

// MySQL Packet Header
const OK: u8 = 0x00;
const EOF: u8 = 0xFE;
const ERR: u8 = 0xFF;

// https://dev.mysql.com/doc/dev/mysql-server/latest/group__group__cs__capabilities__flags.html
const CLIENT_LONG_PASSWORD: u32 = 1;
const CLIENT_FOUND_ROWS: u32 = 2;
const CLIENT_LONG_FLAG: u32 = 4;
const CLIENT_CONNECT_WITH_DB: u32 = 8;
const CLIENT_NO_SCHEMA: u32 = 16;
const CLIENT_COMPRESS: u32 = 32;
const CLIENT_ODBC: u32 = 64;
const CLIENT_LOCAL_FILES: u32 = 128;
const CLIENT_IGNORE_SPACE: u32 = 256;
const CLIENT_PROTOCOL_41: u32 = 512;
const CLIENT_INTERACTIVE: u32 = 1024;
const CLIENT_SSL: u32 = 2048;
const CLIENT_IGNORE_SIGPIPE: u32 = 4096;
const CLIENT_TRANSACTIONS: u32 = 8192;
const CLIENT_RESERVED: u32 = 16384;

const CLIENT_RESERVED2: u32 = 32768;
const CLIENT_MULTI_STATEMENTS: u32 = 1 << 16;
const CLIENT_MULTI_RESULTS: u32 = 1 << 17;
const CLIENT_PS_MULTI_RESULTS: u32 = 1 << 18;
const CLIENT_PLUGIN_AUTH: u32 = 1 << 19;
const CLIENT_CONNECT_ATTRS: u32 = 1 << 20;
const CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA: u32 = 1 << 21;
const CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS: u32 = 1 << 22;
const CLIENT_SESSION_TRACK: u32 = 1 << 23;
const CLIENT_DEPRECATE_EOF: u32 = 1 << 24;
const CLIENT_OPTIONAL_RESULTSET_METADATA: u32 = 1 << 25;
const CLIENT_ZSTD_COMPRESSION_ALGORITHM: u32 = 1 << 26;
const CLIENT_QUERY_ATTRIBUTES: u32 = 1 << 27;
const CTOR_AUTHENTICATION: u32 = 1 << 28;
const CLIENT_CAPABILITY_EXTENSION: u32 = 1 << 29;
const CLIENT_SSL_VERIFY_SERVER_CERT: u32 = 1 << 30;
