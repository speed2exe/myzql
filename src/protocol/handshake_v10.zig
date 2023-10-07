const std = @import("std");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;
const constants = @import("../constants.zig");

pub const HandshakeV10 = struct {
    protocol_version: u8,
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

    pub fn initFromPacket(packet: Packet, capabilities: u32) HandshakeV10 {
        var reader = PacketReader.initFromPacket(packet);
        const protocol_version = reader.readByte();
        std.debug.assert(protocol_version == constants.HANDSHAKE_V10);
        const server_version = reader.readNullTerminatedString();
        const connection_id = reader.readUInt32();
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
            .connection_id = connection_id,
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

    pub fn capability_flags(h: HandshakeV10) u32 {
        var f: u32 = h.capability_flags_2;
        f <<= 16;
        f |= h.capability_flags_1;
        return f;
    }

    pub fn get_auth_plugin_name(h: HandshakeV10) []const u8 {
        return h.auth_plugin_name orelse "mysql_native_password";
    }

    pub fn get_auth_data(h: HandshakeV10) [20]u8 {
        const length = h.auth_plugin_data_part_1.len + h.auth_plugin_data_part_2.len;
        std.debug.assert(length <= 20);
        var auth_data: [20]u8 = undefined;

        const part_1_len = h.auth_plugin_data_part_1.len;
        @memcpy(auth_data[0..part_1_len], h.auth_plugin_data_part_1);
        @memcpy(auth_data[part_1_len..], h.auth_plugin_data_part_2);
        return auth_data;
    }
};
