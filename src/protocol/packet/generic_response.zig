const std = @import("std");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;

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
