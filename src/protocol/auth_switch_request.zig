const std = @import("std");
const constants = @import("../constants.zig");
const Packet = @import("./packet.zig").Packet;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_auth_switch_request.html
pub const AuthSwitchRequest = struct {
    plugin_name: [:0]const u8,
    plugin_data: []const u8,

    pub fn initFromPacket(packet: *const Packet) AuthSwitchRequest {
        var auth_switch_request: AuthSwitchRequest = undefined;
        var reader = packet.reader();
        const header = reader.readByte();
        std.debug.assert(header == constants.AUTH_SWITCH);
        auth_switch_request.plugin_name = reader.readNullTerminatedString();
        auth_switch_request.plugin_data = reader.readRefRemaining();
        return auth_switch_request;
    }
};
