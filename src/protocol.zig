const std = @import("std");
const constants = @import("./constants.zig");

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html#sect_protocol_basic_packets_packet
pub const Packet = struct {
    payload_length: u24,
    sequence_id: u8,
    payload: []const u8,

    pub fn initFromReader(allocator: std.mem.Allocator, std_io_reader: anytype) !Packet {
        const payload_length = try std_io_reader.readIntLittle(u24);
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

    pub fn realize(packet: Packet, capabilities: u32, comptime is_first_packet: bool) PacketRealized {
        const first_byte = packet.payload[0];
        return switch (first_byte) {
            constants.OK => .{ .ok_packet = OkPacket.initFromPacket(packet, capabilities) },
            constants.ERR => .{ .error_packet = ErrorPacket.initFromPacket(is_first_packet, packet, capabilities) },
            constants.EOF => .{ .eof_packet = EofPacket.initFromPacket(packet, capabilities) },
            constants.HANDSHAKE_V10 => .{ .handshake_v10 = HandshakeV10.initFromPacket(packet, capabilities) },
            else => |x| {
                std.log.err("unexpected packet type: {any}\n", .{x});
                unreachable;
            },
        };
    }
};

pub const PacketRealized = union(enum) {
    error_packet: ErrorPacket,
    ok_packet: OkPacket,
    eof_packet: EofPacket,
    handshake_v10: HandshakeV10,
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_err_packet.html
pub const ErrorPacket = struct {
    header: u8, // 0xFF
    error_code: u16,
    sql_state_marker: ?u8,
    sql_state: ?*const [5]u8,
    error_message: []const u8,

    fn initFromPacket(comptime is_first_packet: bool, packet: Packet, capabilities: u32) ErrorPacket {
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.ERR);
        const error_code = reader.readUInt16();

        var sql_state_marker: ?u8 = null;
        var sql_state: ?*const [5]u8 = null;
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

    fn initFromPacket(packet: Packet, capabilities: u32) OkPacket {
        std.debug.assert(packet.payload.len > 7);

        var reader = PacketReader.initFromPacket(packet);

        const header = reader.readByte();
        std.debug.assert(header == constants.OK);

        const affected_rows = reader.readLengthEncodedInteger();
        const last_insert_id = reader.readLengthEncodedInteger();

        var status_flags: ?u16 = null;
        var warnings: ?u16 = null;
        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            status_flags = reader.readUInt16();
            warnings = reader.readUInt16();
        } else if (capabilities & constants.CLIENT_TRANSACTIONS > 0) {
            status_flags = reader.readUInt16();
        }

        var info: []const u8 = undefined;
        var session_state_info: ?[]const u8 = null;
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

        std.debug.assert(reader.finished());
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

    fn initFromPacket(packet: Packet, capabilities: u32) EofPacket {
        std.debug.assert(packet.payload.len < 9);
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.EOF);
        var status_flags: ?u16 = null;
        var warnings: ?u16 = null;
        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            status_flags = reader.readUInt16();
            warnings = reader.readUInt16();
        }

        std.debug.assert(reader.finished());
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
    auth_plugin_data_part_1: *const [8]u8,
    capability_flags_1: u16,
    character_set: u8,
    status_flags: u16,
    capability_flags_2: u16,
    auth_plugin_data_len: ?u8,
    auth_plugin_data_part_2: [:0]const u8,
    auth_plugin_name: ?[:0]const u8,

    fn initFromPacket(packet: Packet, capabilities: u32) HandshakeV10 {
        var reader = PacketReader.initFromPacket(packet);
        const protocol_version = reader.readByte();
        std.debug.assert(protocol_version == constants.HANDSHAKE_V10);
        const server_version = reader.readNullTerminatedString();
        const thread_id = reader.readUInt32();
        const auth_plugin_data_part_1 = reader.readFixed(8);
        _ = reader.readByte(); // filler
        const capability_flags_1 = reader.readUInt16();
        const character_set = reader.readByte();
        const status_flags = reader.readUInt16();
        const capability_flags_2 = reader.readUInt16();

        const auth_plugin_data_len = reader.readByte();

        const reserved = reader.readFixed(10);
        std.debug.assert(std.mem.eql(u8, reserved, &[10]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));

        // This part is not clear in the docs, but it seems like null terminated string works
        // TODO: investigate server code to confirm
        const auth_plugin_data_part_2 = reader.readNullTerminatedString();

        var auth_plugin_name: ?[:0]const u8 = null;
        if (capabilities & constants.CLIENT_PLUGIN_AUTH > 0) {
            auth_plugin_name = reader.readNullTerminatedString();
        }

        std.debug.assert(reader.finished());
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
            .auth_plugin_name = auth_plugin_name,
        };
    }
};

const PacketReader = struct {
    payload: []const u8,
    pos: usize,

    pub fn initFromPacket(packet: Packet) PacketReader {
        return .{ .payload = packet.payload, .pos = 0 };
    }

    fn readFixed(packet_reader: *PacketReader, comptime n: usize) *const [n]u8 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..n];
        packet_reader.pos += n;
        return bytes;
    }

    fn readFixedRuntime(packet_reader: *PacketReader, n: usize) []const u8 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..n];
        packet_reader.pos += n;
        return bytes;
    }

    fn readByte(packet_reader: *PacketReader) u8 {
        const byte = packet_reader.payload[packet_reader.pos];
        packet_reader.pos += 1;
        return byte;
    }

    fn readUInt16(packet_reader: *PacketReader) u16 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..2];
        packet_reader.pos += 2;
        return std.mem.readIntLittle(u16, bytes);
    }

    fn readUInt24(packet_reader: *PacketReader) u24 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..3];
        packet_reader.pos += 3;
        return std.mem.readIntLittle(u24, bytes);
    }

    fn readUInt32(packet_reader: *PacketReader) u32 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..4];
        packet_reader.pos += 4;
        return std.mem.readIntLittle(u32, bytes);
    }

    fn readUInt64(packet_reader: *PacketReader) u64 {
        const bytes = packet_reader.payload[packet_reader.pos..][0..8];
        packet_reader.pos += 8;
        return std.mem.readIntLittle(u64, bytes);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_eof
    fn readRestOfPacketString(packet_reader: *PacketReader) []const u8 {
        const bytes = packet_reader.payload[packet_reader.pos..];
        packet_reader.pos += packet_reader.payload.len;
        return bytes;
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html#sect_protocol_basic_dt_int_le
    // max possible value is 2^64 - 1, so return type is u64
    fn readLengthEncodedInteger(packet_reader: *PacketReader) u64 {
        const first_byte = packet_reader.readByte();
        switch (first_byte) {
            0xFC => return packet_reader.readUInt16(),
            0xFD => return packet_reader.readUInt24(),
            0xFE => return packet_reader.readUInt64(),
            else => return first_byte,
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_le
    fn readLengthEncodedString(packet_reader: *PacketReader) []const u8 {
        const length = packet_reader.readLengthEncodedInteger();
        return packet_reader.readFixedRuntime(@as(usize, length));
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_null
    fn readNullTerminatedString(packet_reader: *PacketReader) [:0]const u8 {
        const start = packet_reader.pos;
        const i = std.mem.indexOfScalarPos(u8, packet_reader.payload, start, 0) orelse {
            std.log.err("null terminated string not found\n, pos: {any}, payload: {any}", .{
                packet_reader.pos,
                packet_reader.payload,
            });
            unreachable;
        };

        const res: [:0]const u8 = @ptrCast(packet_reader.payload[packet_reader.pos..i]);
        packet_reader.pos = i + 1;
        return res;
    }

    fn finished(packet_reader: *PacketReader) bool {
        return packet_reader.pos == packet_reader.payload.len;
    }
};
