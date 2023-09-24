const std = @import("std");
const constants = @import("./constants.zig");

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html#sect_protocol_basic_packets_packet
pub const Packet = struct {
    payload_length: u24,
    sequence_id: u8,
    payload: []const u8,

    pub fn initFromReader(allocator: std.mem.Allocator, std_io_reader: anytype) !Packet {
        const payload_length = try std_io_reader.readIntLittle(3, u24);
        const sequence_id = try std_io_reader.readByte();
        var payload = try allocator.alloc(u8, @as(usize, payload_length));
        const n = try std_io_reader.readAll(payload);
        if (n != payload_length) {
            std.log.err("expected {d} bytes, got {d}\n", .{ payload_length, n });
            return error.ExpectedMorePayload;
        }
        return .{
            .payload_length = payload_length,
            .sequence_id = sequence_id,
            .payload = payload,
        };
    }

    pub fn deinit(packet: Packet, allocator: std.mem.Allocator) void {
        allocator.free(packet.payload);
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_err_packet.html
pub const ErrorPacket = struct {
    header: u8, // 0xFF
    error_code: u16,
    sql_state_marker: ?u8,
    sql_state: ?[5]u8,
    error_message: []const u8,

    fn initFromPacket(
        comptime is_first_packet: bool,
        packet: Packet,
        capabilities: u32,
    ) !void {
        var stream = std.io.fixedBufferStream(packet.payload);
        var stream_reader = stream.reader();
        const header = try stream_reader.readByte();
        if (header != constants.ERR) {
            std.log.err("expected %x packet, got %x\n", .{ constants.ERR, header });
            return error.UnexpectedPacket;
        }
        const error_code = try stream_reader.readIntLittle(2, u16);

        var sql_state_marker = null;
        var sql_state = null;
        if (!is_first_packet and (capabilities & constants.CLIENT_PROTOCOL_41 > 0)) {
            sql_state_marker = try stream_reader.readByte();
            sql_state = try stream_reader.readFixed(5);
        }

        const error_message = try readRestOfPacketString(stream, packet);

        return .{
            .header = header,
            .error_code = error_code,
            .sql_state_marker = sql_state_marker,
            .sql_state = sql_state,
            .error_message = error_message,
        };
    }
};

//https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_ok_packet.html
pub const OkPacket = struct {
    header: u8, // 0x00 or 0xFE
    affected_rows: u64,
    last_insert_id: u64,
    status_flags: ?u16,
    warnings: ?u16,
    info: ?[]const u8,
    session_state_info: ?[]const u8,

    fn initFromPacket(packet: Packet, capabilities: u32) !OkPacket {
        if (!packet.payload.len > 7) {
            std.log.err("expected at least 7 bytes, got {d}\n", .{packet.payload.len});
            return error.OkPacketTooShort;
        }
        var stream = std.io.fixedBufferStream(packet.payload);
        var stream_reader = stream.reader();
        const header = try stream_reader.readByte();
        if (header != constants.OK) {
            std.log.err("expected %x packet, got %x\n", .{ constants.OK, header });
            return error.UnexpectedPacket;
        }

        const affected_rows = readLengthEncodedInteger(stream_reader);
        const last_insert_id = readLengthEncodedInteger(stream_reader);

        var status_flags = null;
        var warnings = null;

        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            status_flags = try stream_reader.readIntLittle(2, u16);
            warnings = try stream_reader.readIntLittle(2, u16);
        } else if (capabilities & constants.CLIENT_TRANSACTIONS > 0) {
            status_flags = try stream_reader.readIntLittle(2, u16);
        }

        var info: []const u8 = undefined;
        var session_state_info = null;
        if (capabilities & constants.CLIENT_SESSION_TRACK > 0) {
            info = try readLengthEncodedString(stream_reader);
            if (status_flags) |sf| {
                if (sf & constants.SERVER_SESSION_STATE_CHANGED > 0) {
                    session_state_info = try readLengthEncodedString(stream_reader);
                }
            }
        } else {
            info = try readRestOfPacketString(stream, packet);
        }

        return .{
            .header = header,
            .affected_rows = affected_rows,
            .last_insert_id = last_insert_id,
            .status_flags = status_flags,
            .warnings = warnings,
            .info = info,
            .session_state_info = session_state_info,
        };
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_eof_packet.html
pub const EofPacket = struct {
    header: u8,
    status_flags: ?u16,
    warnings: ?u16,

    fn initFromPacket(packet: Packet, capabilities: u32) !EofPacket {
        if (!packet.payload.len < 9) {
            std.log.err("expected at most 9 bytes, got {d}\n", .{packet.payload.len});
            return error.EofPacketTooLong;
        }
        var stream = std.io.fixedBufferStream(packet.payload);
        var stream_reader = stream.reader();
        const header = try stream_reader.readByte();
        if (header != constants.EOF) {
            std.log.err("expected %x packet, got %x\n", .{ constants.EOF, header });
            return error.UnexpectedPacket;
        }
        var status_flags = null;
        var warnings = null;
        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            status_flags = try stream_reader.readIntLittle(2, u16);
            warnings = try stream_reader.readIntLittle(2, u16);
        }
        return .{
            .header = header,
            .status_flags = status_flags,
            .warnings = warnings,
        };
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html#sect_protocol_basic_dt_int_le
// max possible value is 2^64 - 1, so return type is u64
fn readLengthEncodedInteger(std_io_reader: anytype) u64 {
    const first_byte = try std_io_reader.readByte();
    switch (first_byte) {
        0xFC => return try std_io_reader.readIntLittle(2, u16),
        0xFD => return try std_io_reader.readIntLittle(3, u24),
        0xFE => return try std_io_reader.readIntLittle(8, u64),
        _ => return first_byte,
    }
}

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_le
fn readLengthEncodedString(std_io_reader: anytype) []const u8 {
    const length = readLengthEncodedInteger(std_io_reader);
    return try std_io_reader.readFixed(@as(usize, length));
}

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_eof
fn readRestOfPacketString(fbs: std.io.FixedBufferStream, packet: Packet) []const u8 {
    const msg_start = try fbs.getPos();
    return packet.payload[msg_start..];
}
