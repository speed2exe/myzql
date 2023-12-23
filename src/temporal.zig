// Type for MYSQL_TYPE_DATE, MYSQL_TYPE_DATETIME and MYSQL_TYPE_TIMESTAMP, i.e. When was it?
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html#sect_protocol_binary_resultset_row_value_date
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32,
};

// Type for MYSQL_TYPE_TIME, i.e. How long did it take?
// `Time` is ambigious and confusing, `Duration` was chosen as the name instead
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html#sect_protocol_binary_resultset_row_value_time
pub const Duration = struct {
    days: u32,
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32,
};
