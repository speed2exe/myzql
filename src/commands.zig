// zig fmt: off

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_utility.html
pub const COM_QUIT             :u8 = 0x01;
pub const COM_INIT_DB          :u8 = 0x02;
pub const COM_FIELD_LIST       :u8 = 0x04;
pub const COM_REFRESH          :u8 = 0x07;
pub const COM_STATISTICS       :u8 = 0x08;
pub const COM_PROCESS_INFO     :u8 = 0x0a;
pub const COM_PROCESS_KILL     :u8 = 0x0c;
pub const COM_DEBUG            :u8 = 0x0d;
pub const COM_PING             :u8 = 0x0e;
pub const COM_CHANGE_USER      :u8 = 0x11;
pub const COM_RESET_CONNECTION :u8 = 0x1f;
pub const COM_SET_OPTION       :u8 = 0x1a;
