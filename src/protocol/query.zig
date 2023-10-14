const std = @import("std");
const stream_buffered = @import("../stream_buffered.zig");

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query.html
pub const TextProtocol = struct {
    pub fn writeAsPacket(h: *const TextProtocol, writer: *stream_buffered.Writer, seq_id: u8) !void {
        _ = seq_id;
        _ = writer;
        _ = h;
    }

    pub fn payload_size(h: *const TextProtocol) u24 {
        _ = h;
    }
};
