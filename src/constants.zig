// zig fmt: off
const std = @import("std");

// MySQL Packet Header
pub const OK:                   u8 = 0x00;
pub const EOF:                  u8 = 0xFE;
pub const AUTH_SWITCH:          u8 = 0xFE;
pub const AUTH_MORE_DATA:       u8 = 0x01;
pub const ERR:                  u8 = 0xFF;
pub const HANDSHAKE_V10:        u8 = 0x0A;
pub const LOCAL_INFILE_REQUEST: u8 = 0xFB;

// Query Result
pub const TEXT_RESULT_ROW_NULL: u8 = 0xFB;

// https://dev.mysql.com/doc/dev/mysql-server/latest/mysql__com_8h.html
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

pub const CLIENT_SECURE_CONNECTION:              u32 = 32768; // Appears deprecated in MySQL but still used in MariaDB
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

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const COM_QUERY:        u8 = 0x03;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_ps.html
pub const COM_STMT_PREPARE: u8 = 0x16;
pub const COM_STMT_EXECUTE: u8 = 0x17;

pub const BINARY_PROTOCOL_RESULTSET_ROW_HEADER: u8 = 0x00;

// https://dev.mysql.com/doc/dev/mysql-server/latest/field__types_8h_source.html
pub const EnumFieldType = enum(u8) {
  MYSQL_TYPE_DECIMAL,
  MYSQL_TYPE_TINY,
  MYSQL_TYPE_SHORT,
  MYSQL_TYPE_LONG,
  MYSQL_TYPE_FLOAT,
  MYSQL_TYPE_DOUBLE,
  MYSQL_TYPE_NULL,
  MYSQL_TYPE_TIMESTAMP,
  MYSQL_TYPE_LONGLONG,
  MYSQL_TYPE_INT24,
  MYSQL_TYPE_DATE,
  MYSQL_TYPE_TIME,
  MYSQL_TYPE_DATETIME,
  MYSQL_TYPE_YEAR,
  MYSQL_TYPE_NEWDATE,
  MYSQL_TYPE_VARCHAR,
  MYSQL_TYPE_BIT,
  MYSQL_TYPE_TIMESTAMP2,
  MYSQL_TYPE_DATETIME2,
  MYSQL_TYPE_TIME2,
  MYSQL_TYPE_TYPED_ARRAY,

  MYSQL_TYPE_INVALID     = 243,
  MYSQL_TYPE_BOOL        = 244,
  MYSQL_TYPE_JSON        = 245,
  MYSQL_TYPE_NEWDECIMAL  = 246,
  MYSQL_TYPE_ENUM        = 247,
  MYSQL_TYPE_SET         = 248,
  MYSQL_TYPE_TINY_BLOB   = 249,
  MYSQL_TYPE_MEDIUM_BLOB = 250,
  MYSQL_TYPE_LONG_BLOB   = 251,
  MYSQL_TYPE_BLOB        = 252,
  MYSQL_TYPE_VAR_STRING  = 253,
  MYSQL_TYPE_STRING      = 254,
  MYSQL_TYPE_GEOMETRY    = 255
};


// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_utility.html
pub const COM_QUIT:             u8 = 0x01;
pub const COM_INIT_DB:          u8 = 0x02;
pub const COM_FIELD_LIST:       u8 = 0x04;
pub const COM_REFRESH:          u8 = 0x07;
pub const COM_STATISTICS:       u8 = 0x08;
pub const COM_PROCESS_INFO:     u8 = 0x0a;
pub const COM_PROCESS_KILL:     u8 = 0x0c;
pub const COM_DEBUG:            u8 = 0x0d;
pub const COM_PING:             u8 = 0x0e;
pub const COM_CHANGE_USER:      u8 = 0x11;
pub const COM_RESET_CONNECTION: u8 = 0x1f;
pub const COM_SET_OPTION:       u8 = 0x1a;

// https://dev.mysql.com/doc/dev/mysql-server/latest/group__group__cs__column__definition__flags.html
pub const NOT_NULL_FLAG:                  u16 = 1;
pub const PRI_KEY_FLAG:                   u16 = 2;
pub const UNIQUE_KEY_FLAG:                u16 = 4;
pub const MULTIPLE_KEY_FLAG:              u16 = 8;
pub const BLOB_FLAG:                      u16 = 16;
pub const UNSIGNED_FLAG:                  u16 = 32;
pub const ZEROFILL_FLAG:                  u16 = 64;
pub const BINARY_FLAG:                    u16 = 128;
pub const ENUM_FLAG:                      u16 = 256;
pub const AUTO_INCREMENT_FLAG:            u16 = 512;
pub const TIMESTAMP_FLAG:                 u16 = 1024;
pub const SET_FLAG:                       u16 = 2048;
pub const NO_DEFAULT_VALUE_FLAG:          u16 = 4096;
pub const ON_UPDATE_NOW_FLAG:             u16 = 8192;
pub const NUM_FLAG:                       u16 = 32768;

pub const PART_KEY_FLAG:                  u16 = 16384;
pub const GROUP_FLAG:                     u16 = 32768;
pub const UNIQUE_FLAG:                    u32 = 65536;
pub const BINCMP_FLAG:                    u32 = 131072;
pub const GET_FIXED_FIELDS_FLAG:          u32 = (1 << 18);
pub const FIELD_IN_PART_FUNC_FLAG:        u32 = (1 << 19);
pub const FIELD_IN_ADD_INDEX:             u32 = (1 << 20);
pub const FIELD_IS_RENAMED:               u32 = (1 << 21);
pub const FIELD_FLAGS_STORAGE_MEDIA:      u32 = 22;
pub const FIELD_FLAGS_STORAGE_MEDIA_MASK: u32 = (3 << FIELD_FLAGS_STORAGE_MEDIA);
pub const FIELD_FLAGS_COLUMN_FORMAT:      u32 = 24;
pub const FIELD_FLAGS_COLUMN_FORMAT_MASK: u32 = (3 << FIELD_FLAGS_COLUMN_FORMAT);
pub const FIELD_IS_DROPPED:               u32 = (1 << 26);
pub const EXPLICIT_NULL_FLAG:             u32 = (1 << 27);
pub const NOT_SECONDARY_FLAG:             u32 = (1 << 29);
pub const FIELD_IS_INVISIBLE:             u32 = (1 << 30);

