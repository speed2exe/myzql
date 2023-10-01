const std = @import("std");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;
const constants = @import("../constants.zig");

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

    pub fn initFromPacket(packet: Packet, capabilities: u32) HandshakeV10 {
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
