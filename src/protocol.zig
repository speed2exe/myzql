const std = @import("std");

pub const Packet = struct {
    allocator: std.mem.Allocator,
    sequence_id: u8,
    payload: []const u8,

    pub fn initFromReader(allocator: std.mem.Allocator, std_io_reader: anytype) !Packet {
        const header = try std_io_reader.readBytesNoEof(4);
        const length = @as(u32, header[0]) | @as(u32, header[1]) << 8 | @as(u32, header[2]) << 16;
        const sequence_id = header[3];

        var payload = try allocator.alloc(u8, length);
        const n = try std_io_reader.readAll(payload);
        if (n != length) {
            std.log.err("expected {d} bytes, got {d}\n", .{ length, n });
            return error.MalformedPacket;
        }
        return .{
            .allocator = allocator,
            .sequence_id = sequence_id,
            .payload = payload,
        };
    }

    pub fn deinit(packet: Packet) void {
        packet.allocator.free(packet.payload);
    }
};

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_v10.html
pub const HandshakeV10 = struct {
    packet: Packet,

    protocol_version: u8,
    server_version: [*:0]const u8,
    thread_id: u32,
    auth_plugin_data_part_1: *const [8]u8,
    filler: u8,
    capability_flags_1: u16,
    character_set: u8,
    status_flags: u16,
    capability_flags_2: u16,
    auth_plugin_data_len: u8,
    reserved: *const [10]u8,
    auth_plugin_data_part_2: *const [13]u8,
    auth_plugin_name: ?[*:0]const u8,

    pub fn initFromPacket(packet: Packet) HandshakeV10 {
        var reader = ProtocolReader.initFromBuffer(packet.payload);

        var handshake: HandshakeV10 = undefined;
        handshake.packet = packet;

        handshake.protocol_version = reader.readUInt8();
        handshake.server_version = reader.readNullTerminatedString().?;
        handshake.thread_id = reader.readUInt32();
        handshake.auth_plugin_data_part_1 = reader.readFixed(8);
        handshake.capability_flags_1 = reader.readUInt16();
        handshake.character_set = reader.readUInt8();
        handshake.status_flags = reader.readUInt16();
        handshake.capability_flags_2 = reader.readUInt16();
        handshake.auth_plugin_data_len = reader.readUInt8();
        handshake.reserved = reader.readFixed(10);
        handshake.auth_plugin_data_part_2 = reader.readFixed(13);
        handshake.auth_plugin_name = reader.readNullTerminatedString();
        return handshake;
    }

    pub fn dump(handshake: HandshakeV10, std_io_writer: anytype) !void {
        try std_io_writer.print("protocol_version: {d}\n", .{handshake.protocol_version});
        try std_io_writer.print("server_version: {s}\n", .{handshake.server_version});
        try std_io_writer.print("thread_id: {d}\n", .{handshake.thread_id});
        try std_io_writer.print("auth_plugin_data: {x}\n", .{std.fmt.fmtSliceHexLower(handshake.auth_plugin_data_part_1)});
        try std_io_writer.print("capability_flags_1: {x}\n", .{handshake.capability_flags_1});
        try std_io_writer.print("character_set: {d}\n", .{handshake.character_set});
        try std_io_writer.print("status_flags: {x}\n", .{handshake.status_flags});
        try std_io_writer.print("capability_flags_2: {x}\n", .{handshake.capability_flags_2});
        try std_io_writer.print("auth_plugin_data_len: {d}\n", .{handshake.auth_plugin_data_len});
        try std_io_writer.print("reserved: {x}\n", .{std.fmt.fmtSliceHexLower(handshake.reserved)});
        try std_io_writer.print("auth_plugin_data_part_2: {x}\n", .{std.fmt.fmtSliceHexLower(handshake.auth_plugin_data_part_2)});
        try std_io_writer.print("auth_plugin_name: {s}\n", .{handshake.auth_plugin_name orelse "NULL"});
    }

    pub fn deinit(h: HandshakeV10) void {
        h.packet.deinit();
    }
};

const ProtocolReader = struct {
    buffer: []const u8,
    pos: usize,

    fn initFromBuffer(buffer: []const u8) ProtocolReader {
        return .{ .buffer = buffer, .pos = 0 };
    }

    fn readUInt8(p: *ProtocolReader) u8 {
        const b = p.buffer[p.pos];
        p.pos += 1;
        return b;
    }

    fn readUInt16(p: *ProtocolReader) u16 {
        const b = std.mem.readIntSliceLittle(u16, p.buffer[p.pos .. p.pos + 2]);
        p.pos += 2;
        return b;
    }

    fn readUInt32(p: *ProtocolReader) u32 {
        const b = std.mem.readIntSliceLittle(u32, p.buffer[p.pos .. p.pos + 4]);
        p.pos += 2;
        return b;
    }

    fn readFixed(p: *ProtocolReader, comptime size: usize) *const [size]u8 {
        const s: *const [size]u8 = @ptrCast(&p.buffer[p.pos]);
        p.pos += size;
        return s;
    }

    fn readNullTerminatedString(p: *ProtocolReader) ?[*:0]const u8 {
        const s: [*:0]const u8 = @ptrCast(&p.buffer[p.pos]);
        p.pos = std.mem.indexOfScalarPos(u8, p.buffer, p.pos, 0) orelse return null;
        return s;
    }
};
