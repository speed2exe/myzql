const std = @import("std");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_err_packet.html
pub const ErrorPacket = struct {
    error_code: u16,
    sql_state_marker: ?u8,
    sql_state: ?*const [5]u8,
    error_message: []const u8,

    pub fn initFromPacket(comptime is_first_packet: bool, packet: *const Packet, capabilities: u32) ErrorPacket {
        var error_packet: ErrorPacket = undefined;

        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.ERR);

        error_packet.error_code = reader.readUInt16();
        if (!is_first_packet and (capabilities & constants.CLIENT_PROTOCOL_41 > 0)) {
            error_packet.sql_state_marker = reader.readByte();
            error_packet.sql_state = reader.readFixed(5);
        } else {
            error_packet.sql_state_marker = null;
            error_packet.sql_state = null;
        }
        error_packet.error_message = reader.readRestOfPacketString();
        return error_packet;
    }

    pub fn asError(err: *const ErrorPacket) error{ErrorPacket} {
        // TODO: better way to do this?
        std.log.err(
            "error packet: (code: {d}, message: {s})",
            .{ err.error_code, err.error_message },
        );
        return error.ErrorPacket;
    }
};

//https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_ok_packet.html
pub const OkPacket = struct {
    affected_rows: u64,
    last_insert_id: u64,
    status_flags: ?u16,
    warnings: ?u16,
    info: ?[]const u8,
    session_state_info: ?[]const u8,

    pub fn initFromPacket(packet: *const Packet, capabilities: u32) OkPacket {
        var ok_packet: OkPacket = undefined;

        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.OK);

        ok_packet.affected_rows = reader.readLengthEncodedInteger();
        ok_packet.last_insert_id = reader.readLengthEncodedInteger();

        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            ok_packet.status_flags = reader.readUInt16();
            ok_packet.warnings = reader.readUInt16();
        } else if (capabilities & constants.CLIENT_TRANSACTIONS > 0) {
            ok_packet.status_flags = reader.readUInt16();
            ok_packet.warnings = null;
        } else {
            ok_packet.status_flags = null;
            ok_packet.warnings = null;
        }

        ok_packet.session_state_info = null;
        if (capabilities & constants.CLIENT_SESSION_TRACK > 0) {
            ok_packet.info = reader.readLengthEncodedString();
            if (ok_packet.status_flags) |sf| {
                if (sf & constants.SERVER_SESSION_STATE_CHANGED > 0) {
                    ok_packet.session_state_info = reader.readLengthEncodedString();
                }
            }
        } else {
            ok_packet.info = reader.readRestOfPacketString();
        }

        std.debug.assert(reader.finished());
        return ok_packet;
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_eof_packet.html
pub const EofPacket = struct {
    header: u8,
    status_flags: ?u16,
    warnings: ?u16,

    pub fn initFromPacket(packet: *const Packet, capabilities: u32) EofPacket {
        var eof_packet: EofPacket = undefined;

        std.debug.assert(packet.payload.len < 9);
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.EOF);

        eof_packet.status_flags = null;
        eof_packet.warnings = null;
        if (capabilities & constants.CLIENT_PROTOCOL_41 > 0) {
            eof_packet.status_flags = reader.readUInt16();
            eof_packet.warnings = reader.readUInt16();
        }

        std.debug.assert(reader.finished());
        return eof_packet;
    }
};
