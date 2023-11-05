const std = @import("std");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;
const constants = @import("../constants.zig");
const AuthPlugin = @import("../auth.zig").AuthPlugin;

pub const HandshakeV10 = struct {
    server_version: [:0]const u8,
    connection_id: u32,
    auth_plugin_data_part_1: *const [8]u8,
    capability_flags_1: u16,
    character_set: u8,
    status_flags: u16,
    capability_flags_2: u16,
    auth_plugin_data_len: ?u8,
    auth_plugin_data_part_2: [:0]const u8,
    auth_plugin_name: ?[:0]const u8,

    pub fn initFromPacket(packet: *const Packet, capabilities: u32) HandshakeV10 {
        var handshake_v10: HandshakeV10 = undefined;

        var reader = PacketReader.initFromPacket(packet);
        const protocol_version = reader.readByte();
        std.debug.assert(protocol_version == constants.HANDSHAKE_V10);

        handshake_v10.server_version = reader.readNullTerminatedString();
        handshake_v10.connection_id = reader.readUInt32();
        handshake_v10.auth_plugin_data_part_1 = reader.readFixed(8);
        _ = reader.readByte(); // filler
        handshake_v10.capability_flags_1 = reader.readUInt16();
        handshake_v10.character_set = reader.readByte();
        handshake_v10.status_flags = reader.readUInt16();
        handshake_v10.capability_flags_2 = reader.readUInt16();

        handshake_v10.auth_plugin_data_len = reader.readByte();

        const reserved = reader.readFixed(10);
        std.debug.assert(std.mem.eql(u8, reserved, &[10]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));

        // This part ambiguous in mariadb and mysql,
        // It seems like null terminated string works for both, at least for now
        // https://mariadb.com/kb/en/connection/#initial-handshake-packet
        // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_v10.html
        handshake_v10.auth_plugin_data_part_2 = reader.readNullTerminatedString();

        if (capabilities & constants.CLIENT_PLUGIN_AUTH > 0) {
            handshake_v10.auth_plugin_name = reader.readNullTerminatedString();
        } else {
            handshake_v10.auth_plugin_name = null;
        }

        std.debug.assert(reader.finished());
        return handshake_v10;
    }

    pub fn capability_flags(h: *const HandshakeV10) u32 {
        var f: u32 = h.capability_flags_2;
        f <<= 16;
        f |= h.capability_flags_1;
        return f;
    }

    pub fn get_auth_plugin(h: *const HandshakeV10) AuthPlugin {
        const name = h.auth_plugin_name orelse return .unspecified;
        return AuthPlugin.fromName(name);
    }

    pub fn get_auth_data(h: *const HandshakeV10) [20]u8 {
        const length = h.auth_plugin_data_part_1.len + h.auth_plugin_data_part_2.len;
        std.debug.assert(length <= 20);
        var auth_data: [20]u8 = undefined;

        const part_1_len = h.auth_plugin_data_part_1.len;
        @memcpy(auth_data[0..part_1_len], h.auth_plugin_data_part_1);
        @memcpy(auth_data[part_1_len..], h.auth_plugin_data_part_2);
        return auth_data;
    }
};
