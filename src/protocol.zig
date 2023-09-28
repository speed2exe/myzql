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
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        if (header != constants.ERR) {
            std.log.err("expected %x packet, got %x\n", .{ constants.ERR, header });
            return error.UnexpectedPacket;
        }
        const error_code = reader.readIntLittle(2, u16);

        var sql_state_marker = null;
        var sql_state = null;
        if (!is_first_packet and (capabilities & constants.CLIENT_PROTOCOL_41 > 0)) {
            sql_state_marker = reader.readByte();
            sql_state = reader.readFixed(5);
        }

        const error_message = reader.readRestOfPacketString();
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
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.OK);

        const affected_rows = reader.readLengthEncodedInteger();
        const last_insert_id = reader.readLengthEncodedInteger();

        var status_flags = null;
        var warnings = null;

        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            status_flags = reader.readIntLittle(2, u16);
            warnings = reader.readIntLittle(2, u16);
        } else if (capabilities & constants.CLIENT_TRANSACTIONS > 0) {
            status_flags = reader.readIntLittle(2, u16);
        }

        var info: []const u8 = undefined;
        var session_state_info = null;
        if (capabilities & constants.CLIENT_SESSION_TRACK > 0) {
            info = reader.readLengthEncodedString();
            if (status_flags) |sf| {
                if (sf & constants.SERVER_SESSION_STATE_CHANGED > 0) {
                    session_state_info = reader.readLengthEncodedString();
                }
            }
        } else {
            info = reader.readRestOfPacketString();
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
        std.debug.assert(packet.payload.len < 9);
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.EOF);
        var status_flags = null;
        var warnings = null;
        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            status_flags = reader.readUInt16();
            warnings = reader.readUInt16();
        }
        return .{
            .header = header,
            .status_flags = status_flags,
            .warnings = warnings,
        };
    }
};

pub const HandshakeV10 = struct {
    protocol_version: u8,
    server_version: [:0]const u8,
    thread_id: u32,
    auth_plugin_data_part_1: [8]u8,
    capability_flags_1: u16,
    character_set: u8,
    status_flags: u16,
    capability_flags_2: u16,
    auth_plugin_data_len: ?u8,
    auth_plugin_data_part_2: []const u8,
    auth_plugin_name: [:0]const u8,

    fn initFromPacket(
        packet: Packet,
    ) !void {
        var reader = PacketReader.initFromPacket(packet);
        const protocol_version = reader.readByte();
        std.debug.assert(protocol_version == constants.HANDSHAKE_V10);
        const server_version = reader.readNullTerminatedString();
        const thread_id = reader.readUInt32();
        const auth_plugin_data_part_1 = reader.readFixed(8);
        const capability_flags_1 = reader.readUInt16();
        const character_set = reader.readByte();
        const status_flags = reader.readUInt16();
        const capability_flags_2 = reader.readUInt16();

        const auth_plugin_data_len = reader.readByte();

        const reserved = reader.readFixed(10);
        std.debug.assert(reserved == []const u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

        // length = max(13, auth_plugin_data_len - 8);
        const remain_auth_data_length = auth_plugin_data_len - 13;
        const auth_plugin_data_part_2 = reader.readFixed(remain_auth_data_length);

        return .{
            .protocol_version = protocol_version,
            .server_version = server_version,
            .thread_id = thread_id,
            .auth_plugin_data_part_1 = auth_plugin_data_part_1,
            .capability_flags_1 = capability_flags_1,
            .character_set = character_set,
            .status_flags = status_flags,
            .capability_flags_2 = capability_flags_2,
            .auth_plugin_data_len = auth_plugin_data_len,
            .auth_plugin_data_part_2 = auth_plugin_data_part_2,
        };
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_null
// fn readNullTerminatedString(fbs: std.io.FixedBufferStream, packet: Packet) [:0]const u8 {
//
// }

const PacketReader = struct {
    payload: []const u8,
    pos: usize,

    pub fn initFromPacket(packet: Packet) PacketReader {
        return .{ .payload = packet.payload, .pos = 0 };
    }

    fn readFixed(packet_reader: PacketReader, comptime n: usize) []const u8 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..n];
        packet_reader.pos += n;
        return bytes;
    }

    fn readByte(packet_reader: PacketReader) u8 {
        const byte = packet_reader.payload[packet_reader.pos];
        packet_reader.pos += 1;
        return byte;
    }

    fn readUInt16(packet_reader: PacketReader) u16 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..2];
        return std.mem.readIntLittle(u16, bytes);
    }

    fn readUInt24(packet_reader: PacketReader) u24 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..3];
        return std.mem.readIntLittle(u24, bytes);
    }

    fn readUInt64(packet_reader: PacketReader) u64 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..8];
        return std.mem.readIntLittle(u64, bytes);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_eof
    fn readRestOfPacketString(packet_reader: PacketReader) []const u8 {
        return packet_reader.payload[packet_reader.pos..];
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html#sect_protocol_basic_dt_int_le
    // max possible value is 2^64 - 1, so return type is u64
    fn readLengthEncodedInteger(packet_reader: PacketReader) u64 {
        const first_byte = packet_reader.readByte();
        switch (first_byte) {
            0xFC => return packet_reader.readUInt16(),
            0xFD => return packet_reader.readUInt24(),
            0xFE => return packet_reader.readUInt64(),
            _ => return first_byte,
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_le
    fn readLengthEncodedString(packet_reader: PacketReader) []const u8 {
        const length = packet_reader.readLengthEncodedInteger();
        return packet_reader.readFixed(@as(usize, length));
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_null
    fn readNullTerminatedString(packet_reader: PacketReader) [:0]const u8 {
        const start = packet_reader.pos;
        const i = std.mem.indexOfScalarPos(u8, packet_reader.payload, start, 0) orelse {
            std.log.err("null terminated string not found\n, pos: {}, payload: {}", .{
                packet_reader.pos,
                packet_reader.payload,
            });
            return error.NullTerminatedStringNotFound;
        };

        const res: [:0]const u8 = @ptrCast(packet_reader.payload[packet_reader.pos..i]);
        packet_reader.pos = i + 1;
        return res;
    }
};
