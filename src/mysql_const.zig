const default_auth_plugin = "mysql_native_password";

// MySQL constants documentation:
// http://dev.mysql.com/doc/internals/en/client-server-protocol.html

const i_ok: u8 = 0x00;
const i_auth_more_data: u8 = 0x01;
const i_local_in_file: u8 = 0xfb;
const i_eof: u8 = 0xfe;
const i_err: u8 = 0xff;

const min_protocol_version = 10;

// https://dev.mysql.com/doc/internals/en/capability-flags.html#packet-Protocol::CapabilityFlags
const client_long_password: u32 = 1 << 0;
const client_found_rows = 1 << 1;
const client_long_flag = 1 << 2;
const client_connect_with_db = 1 << 3;
const client_no_schema = 1 << 4;
const client_compress = 1 << 5;
const client_odbc = 1 << 6;
const client_local_files = 1 << 7;
const client_ignore_space = 1 << 8;
const client_protocol_41 = 1 << 9;
const client_interactive = 1 << 10;
const client_ssl = 1 << 11;
const client_ignore_sigpipe = 1 << 12;
const client_transactions = 1 << 13;
const client_reserved = 1 << 14;
const client_secure_conn = 1 << 15;
const client_multi_statements = 1 << 16;
const client_multi_results = 1 << 17;
const client_ps_multi_results = 1 << 18;
const client_plugin_auth = 1 << 19;
const client_connect_attrs = 1 << 20;
const client_plugin_auth_len_enc_client_data = 1 << 21;
const client_can_handle_expired_passwords = 1 << 22;
const client_session_track = 1 << 23;
const client_deprecate_eof = 1 << 24;
