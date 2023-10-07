const std = @import("std");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;
const PacketReader = @import("./packet_reader.zig").PacketReader;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_auth_switch_request.html
pub const AuthSwitchRequest = struct {
    header: u8, // 0xFE
    plugin_name: [:0]const u8,
    plugin_data: []const u8,

    pub fn initFromPacket(packet: Packet) AuthSwitchRequest {
        var reader = PacketReader.initFromPacket(packet);
        const header = reader.readByte();
        std.debug.assert(header == constants.AUTH_SWITCH);

        const plugin_name = reader.readNullTerminatedString();
        const plugin_data = reader.readRestOfPacketString();
        return .{
            .header = header,
            .plugin_name = plugin_name,
            .plugin_data = plugin_data,
        };
    }
};
