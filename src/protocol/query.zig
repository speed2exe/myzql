const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const TextProtocol = struct {
    query: []const u8,
    // TODO: support params

    pub fn write(h: *const TextProtocol, writer: *stream_buffered.Writer) !void {
        _ = writer;
        _ = h;
    }
};
