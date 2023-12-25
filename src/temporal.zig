// Type for MYSQL_TYPE_DATE, MYSQL_TYPE_DATETIME and MYSQL_TYPE_TIMESTAMP, i.e. When was it?
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html#sect_protocol_binary_resultset_row_value_date
pub const DateTime = struct {
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    microsecond: u32 = 0,
};

// Type for MYSQL_TYPE_TIME, i.e. How long did it take?
// `Time` is ambigious and confusing, `Duration` was chosen as the name instead
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html#sect_protocol_binary_resultset_row_value_time
pub const Duration = struct {
    is_negative: u8 = 0, // 1 if minus, 0 for plus
    days: u32 = 0,
    hours: u8 = 0,
    minutes: u8 = 0,
    seconds: u8 = 0,
    microseconds: u32 = 0,
};
