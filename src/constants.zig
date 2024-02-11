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

// Derive from:
// SELECT COLLATION_NAME, ID FROM information_schema.COLLATIONS WHERE ID < 256 ORDER BY ID
pub const big5_chinese_ci:              u8 =   1;
pub const latin2_czech_cs:              u8 =   2;
pub const dec8_swedish_ci:              u8 =   3;
pub const cp850_general_ci:             u8 =   4;
pub const latin1_german1_ci:            u8 =   5;
pub const hp8_english_ci:               u8 =   6;
pub const koi8r_general_ci:             u8 =   7;
pub const latin1_swedish_ci:            u8 =   8;
pub const latin2_general_ci:            u8 =   9;
pub const swe7_swedish_ci:              u8 =  10;
pub const ascii_general_ci:             u8 =  11;
pub const ujis_japanese_ci:             u8 =  12;
pub const sjis_japanese_ci:             u8 =  13;
pub const cp1251_bulgarian_ci:          u8 =  14;
pub const latin1_danish_ci:             u8 =  15;
pub const hebrew_general_ci:            u8 =  16;
pub const tis620_thai_ci:               u8 =  18;
pub const euckr_korean_ci:              u8 =  19;
pub const latin7_estonian_cs:           u8 =  20;
pub const latin2_hungarian_ci:          u8 =  21;
pub const koi8u_general_ci:             u8 =  22;
pub const cp1251_ukrainian_ci:          u8 =  23;
pub const gb2312_chinese_ci:            u8 =  24;
pub const greek_general_ci:             u8 =  25;
pub const cp1250_general_ci:            u8 =  26;
pub const latin2_croatian_ci:           u8 =  27;
pub const gbk_chinese_ci:               u8 =  28;
pub const cp1257_lithuanian_ci:         u8 =  29;
pub const latin5_turkish_ci:            u8 =  30;
pub const latin1_german2_ci:            u8 =  31;
pub const armscii8_general_ci:          u8 =  32;
pub const utf8mb3_general_ci:           u8 =  33;
pub const cp1250_czech_cs:              u8 =  34;
pub const ucs2_general_ci:              u8 =  35;
pub const cp866_general_ci:             u8 =  36;
pub const keybcs2_general_ci:           u8 =  37;
pub const macce_general_ci:             u8 =  38;
pub const macroman_general_ci:          u8 =  39;
pub const cp852_general_ci:             u8 =  40;
pub const latin7_general_ci:            u8 =  41;
pub const latin7_general_cs:            u8 =  42;
pub const macce_bin:                    u8 =  43;
pub const cp1250_croatian_ci:           u8 =  44;
pub const utf8mb4_general_ci:           u8 =  45;
pub const utf8mb4_bin:                  u8 =  46;
pub const latin1_bin:                   u8 =  47;
pub const latin1_general_ci:            u8 =  48;
pub const latin1_general_cs:            u8 =  49;
pub const cp1251_bin:                   u8 =  50;
pub const cp1251_general_ci:            u8 =  51;
pub const cp1251_general_cs:            u8 =  52;
pub const macroman_bin:                 u8 =  53;
pub const utf16_general_ci:             u8 =  54;
pub const utf16_bin:                    u8 =  55;
pub const utf16le_general_ci:           u8 =  56;
pub const cp1256_general_ci:            u8 =  57;
pub const cp1257_bin:                   u8 =  58;
pub const cp1257_general_ci:            u8 =  59;
pub const utf32_general_ci:             u8 =  60;
pub const utf32_bin:                    u8 =  61;
pub const utf16le_bin:                  u8 =  62;
pub const binary:                       u8 =  63;
pub const armscii8_bin:                 u8 =  64;
pub const ascii_bin:                    u8 =  65;
pub const cp1250_bin:                   u8 =  66;
pub const cp1256_bin:                   u8 =  67;
pub const cp866_bin:                    u8 =  68;
pub const dec8_bin:                     u8 =  69;
pub const greek_bin:                    u8 =  70;
pub const hebrew_bin:                   u8 =  71;
pub const hp8_bin:                      u8 =  72;
pub const keybcs2_bin:                  u8 =  73;
pub const koi8r_bin:                    u8 =  74;
pub const koi8u_bin:                    u8 =  75;
pub const utf8mb3_tolower_ci:           u8 =  76;
pub const latin2_bin:                   u8 =  77;
pub const latin5_bin:                   u8 =  78;
pub const latin7_bin:                   u8 =  79;
pub const cp850_bin:                    u8 =  80;
pub const cp852_bin:                    u8 =  81;
pub const swe7_bin:                     u8 =  82;
pub const utf8mb3_bin:                  u8 =  83;
pub const big5_bin:                     u8 =  84;
pub const euckr_bin:                    u8 =  85;
pub const gb2312_bin:                   u8 =  86;
pub const gbk_bin:                      u8 =  87;
pub const sjis_bin:                     u8 =  88;
pub const tis620_bin:                   u8 =  89;
pub const ucs2_bin:                     u8 =  90;
pub const ujis_bin:                     u8 =  91;
pub const geostd8_general_ci:           u8 =  92;
pub const geostd8_bin:                  u8 =  93;
pub const latin1_spanish_ci:            u8 =  94;
pub const cp932_japanese_ci:            u8 =  95;
pub const cp932_bin:                    u8 =  96;
pub const eucjpms_japanese_ci:          u8 =  97;
pub const eucjpms_bin:                  u8 =  98;
pub const cp1250_polish_ci:             u8 =  99;
pub const utf16_unicode_ci:             u8 = 101;
pub const utf16_icelandic_ci:           u8 = 102;
pub const utf16_latvian_ci:             u8 = 103;
pub const utf16_romanian_ci:            u8 = 104;
pub const utf16_slovenian_ci:           u8 = 105;
pub const utf16_polish_ci:              u8 = 106;
pub const utf16_estonian_ci:            u8 = 107;
pub const utf16_spanish_ci:             u8 = 108;
pub const utf16_swedish_ci:             u8 = 109;
pub const utf16_turkish_ci:             u8 = 110;
pub const utf16_czech_ci:               u8 = 111;
pub const utf16_danish_ci:              u8 = 112;
pub const utf16_lithuanian_ci:          u8 = 113;
pub const utf16_slovak_ci:              u8 = 114;
pub const utf16_spanish2_ci:            u8 = 115;
pub const utf16_roman_ci:               u8 = 116;
pub const utf16_persian_ci:             u8 = 117;
pub const utf16_esperanto_ci:           u8 = 118;
pub const utf16_hungarian_ci:           u8 = 119;
pub const utf16_sinhala_ci:             u8 = 120;
pub const utf16_german2_ci:             u8 = 121;
pub const utf16_croatian_ci:            u8 = 122;
pub const utf16_unicode_520_ci:         u8 = 123;
pub const utf16_vietnamese_ci:          u8 = 124;
pub const ucs2_unicode_ci:              u8 = 128;
pub const ucs2_icelandic_ci:            u8 = 129;
pub const ucs2_latvian_ci:              u8 = 130;
pub const ucs2_romanian_ci:             u8 = 131;
pub const ucs2_slovenian_ci:            u8 = 132;
pub const ucs2_polish_ci:               u8 = 133;
pub const ucs2_estonian_ci:             u8 = 134;
pub const ucs2_spanish_ci:              u8 = 135;
pub const ucs2_swedish_ci:              u8 = 136;
pub const ucs2_turkish_ci:              u8 = 137;
pub const ucs2_czech_ci:                u8 = 138;
pub const ucs2_danish_ci:               u8 = 139;
pub const ucs2_lithuanian_ci:           u8 = 140;
pub const ucs2_slovak_ci:               u8 = 141;
pub const ucs2_spanish2_ci:             u8 = 142;
pub const ucs2_roman_ci:                u8 = 143;
pub const ucs2_persian_ci:              u8 = 144;
pub const ucs2_esperanto_ci:            u8 = 145;
pub const ucs2_hungarian_ci:            u8 = 146;
pub const ucs2_sinhala_ci:              u8 = 147;
pub const ucs2_german2_ci:              u8 = 148;
pub const ucs2_croatian_ci:             u8 = 149;
pub const ucs2_unicode_520_ci:          u8 = 150;
pub const ucs2_vietnamese_ci:           u8 = 151;
pub const ucs2_general_mysql500_ci:     u8 = 159;
pub const utf32_unicode_ci:             u8 = 160;
pub const utf32_icelandic_ci:           u8 = 161;
pub const utf32_latvian_ci:             u8 = 162;
pub const utf32_romanian_ci:            u8 = 163;
pub const utf32_slovenian_ci:           u8 = 164;
pub const utf32_polish_ci:              u8 = 165;
pub const utf32_estonian_ci:            u8 = 166;
pub const utf32_spanish_ci:             u8 = 167;
pub const utf32_swedish_ci:             u8 = 168;
pub const utf32_turkish_ci:             u8 = 169;
pub const utf32_czech_ci:               u8 = 170;
pub const utf32_danish_ci:              u8 = 171;
pub const utf32_lithuanian_ci:          u8 = 172;
pub const utf32_slovak_ci:              u8 = 173;
pub const utf32_spanish2_ci:            u8 = 174;
pub const utf32_roman_ci:               u8 = 175;
pub const utf32_persian_ci:             u8 = 176;
pub const utf32_esperanto_ci:           u8 = 177;
pub const utf32_hungarian_ci:           u8 = 178;
pub const utf32_sinhala_ci:             u8 = 179;
pub const utf32_german2_ci:             u8 = 180;
pub const utf32_croatian_ci:            u8 = 181;
pub const utf32_unicode_520_ci:         u8 = 182;
pub const utf32_vietnamese_ci:          u8 = 183;
pub const utf8mb3_unicode_ci:           u8 = 192;
pub const utf8mb3_icelandic_ci:         u8 = 193;
pub const utf8mb3_latvian_ci:           u8 = 194;
pub const utf8mb3_romanian_ci:          u8 = 195;
pub const utf8mb3_slovenian_ci:         u8 = 196;
pub const utf8mb3_polish_ci:            u8 = 197;
pub const utf8mb3_estonian_ci:          u8 = 198;
pub const utf8mb3_spanish_ci:           u8 = 199;
pub const utf8mb3_swedish_ci:           u8 = 200;
pub const utf8mb3_turkish_ci:           u8 = 201;
pub const utf8mb3_czech_ci:             u8 = 202;
pub const utf8mb3_danish_ci:            u8 = 203;
pub const utf8mb3_lithuanian_ci:        u8 = 204;
pub const utf8mb3_slovak_ci:            u8 = 205;
pub const utf8mb3_spanish2_ci:          u8 = 206;
pub const utf8mb3_roman_ci:             u8 = 207;
pub const utf8mb3_persian_ci:           u8 = 208;
pub const utf8mb3_esperanto_ci:         u8 = 209;
pub const utf8mb3_hungarian_ci:         u8 = 210;
pub const utf8mb3_sinhala_ci:           u8 = 211;
pub const utf8mb3_german2_ci:           u8 = 212;
pub const utf8mb3_croatian_ci:          u8 = 213;
pub const utf8mb3_unicode_520_ci:       u8 = 214;
pub const utf8mb3_vietnamese_ci:        u8 = 215;
pub const utf8mb3_general_mysql500_ci:  u8 = 223;
pub const utf8mb4_unicode_ci:           u8 = 224;
pub const utf8mb4_icelandic_ci:         u8 = 225;
pub const utf8mb4_latvian_ci:           u8 = 226;
pub const utf8mb4_romanian_ci:          u8 = 227;
pub const utf8mb4_slovenian_ci:         u8 = 228;
pub const utf8mb4_polish_ci:            u8 = 229;
pub const utf8mb4_estonian_ci:          u8 = 230;
pub const utf8mb4_spanish_ci:           u8 = 231;
pub const utf8mb4_swedish_ci:           u8 = 232;
pub const utf8mb4_turkish_ci:           u8 = 233;
pub const utf8mb4_czech_ci:             u8 = 234;
pub const utf8mb4_danish_ci:            u8 = 235;
pub const utf8mb4_lithuanian_ci:        u8 = 236;
pub const utf8mb4_slovak_ci:            u8 = 237;
pub const utf8mb4_spanish2_ci:          u8 = 238;
pub const utf8mb4_roman_ci:             u8 = 239;
pub const utf8mb4_persian_ci:           u8 = 240;
pub const utf8mb4_esperanto_ci:         u8 = 241;
pub const utf8mb4_hungarian_ci:         u8 = 242;
pub const utf8mb4_sinhala_ci:           u8 = 243;
pub const utf8mb4_german2_ci:           u8 = 244;
pub const utf8mb4_croatian_ci:          u8 = 245;
pub const utf8mb4_unicode_520_ci:       u8 = 246;
pub const utf8mb4_vietnamese_ci:        u8 = 247;
pub const gb18030_chinese_ci:           u8 = 248;
pub const gb18030_bin:                  u8 = 249;
pub const gb18030_unicode_520_ci:       u8 = 250;
pub const utf8mb4_0900_ai_ci:           u8 = 255;
