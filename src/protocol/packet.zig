const std = @import("std");
const constants = @import("../constants.zig");
const ErrorPacket = @import("./generic_response.zig").ErrorPacket;
const Config = @import("../config.zig").Config;
const logger = @import("../logger.zig");
// const PacketReader = @import("./packet_reader.zig").PacketReader;

// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html#sect_protocol_basic_packets_packet
pub const Packet = struct {
    sequence_id: u8,
    payload: []const u8,

    /// Config of the connection the packet was read from, `null` for a packet
    /// that was built by hand. Used to bind the log messages derived from this
    /// packet to the connection they belong to, through its config.
    config: ?*const Config = null,

    pub fn init(sequence_id: u8, payload: []const u8) Packet {
        return .{ .sequence_id = sequence_id, .payload = payload };
    }

    pub fn asError(packet: *const Packet) error{ UnexpectedPacket, ErrorPacket } {
        if (packet.payload[0] == constants.ERR) {
            return ErrorPacket.init(packet).asError();
        }
        // printed field by field, `{any}` would include the config
        logger.log(packet.config, .warn, "unexpected packet: (sequence_id: {d}, payload: {any})", .{ packet.sequence_id, packet.payload });
        return error.UnexpectedPacket;
    }

    pub fn reader(packet: *const Packet) PayloadReader {
        var payload_reader = PayloadReader.init(packet.payload);
        payload_reader.config = packet.config;
        return payload_reader;
    }

    pub fn cloneAlloc(packet: *const Packet, allocator: std.mem.Allocator) !Packet {
        const payload_copy = try allocator.dupe(u8, packet.payload);
        return .{
            .sequence_id = packet.sequence_id,
            .payload = payload_copy,
            .config = packet.config,
        };
    }

    pub fn deinit(packet: *const Packet, allocator: std.mem.Allocator) void {
        allocator.free(packet.payload);
    }
};

pub const PayloadReader = struct {
    payload: []const u8,
    pos: usize,
    /// Config of the connection the payload was read from, used to bind log
    /// messages.
    config: ?*const Config = null,

    fn init(payload: []const u8) PayloadReader {
        return .{ .payload = payload, .pos = 0 };
    }

    pub fn peek(p: *const PayloadReader) ?u8 {
        std.debug.assert(p.pos <= p.payload.len);
        if (p.pos == p.payload.len) {
            return null;
        }
        return p.payload[p.pos];
    }

    pub fn readByte(p: *PayloadReader) u8 {
        std.debug.assert(p.pos <= p.payload.len);
        const byte = p.payload[p.pos];
        p.pos += 1;
        return byte;
    }

    pub fn readInt(p: *PayloadReader, Int: type) Int {
        const bytes = p.readRefComptime(@divExact(@typeInfo(Int).int.bits, 8));
        return std.mem.readInt(Int, bytes, .little);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_eof
    pub fn readRefRemaining(p: *PayloadReader) []const u8 {
        return p.readRefRuntime(p.payload.len - p.pos);
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_integers.html#sect_protocol_basic_dt_int_le
    // max possible value is 2^64 - 1, so return type is u64
    pub fn readLengthEncodedInteger(p: *PayloadReader) u64 {
        const first_byte = p.readByte();
        switch (first_byte) {
            0xFC => return p.readInt(u16),
            0xFD => return p.readInt(u24),
            0xFE => return p.readInt(u64),
            else => return first_byte,
        }
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_le
    pub fn readLengthEncodedString(p: *PayloadReader) []const u8 {
        const length = p.readLengthEncodedInteger();
        return p.readRefRuntime(@as(usize, length));
    }

    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_dt_strings.html#sect_protocol_basic_dt_string_null
    pub fn readNullTerminatedString(p: *PayloadReader) [:0]const u8 {
        const i = std.mem.indexOfScalarPos(u8, p.payload, p.pos, 0) orelse {
            logger.log(p.config, .warn, "null terminated string not found\n, pos: {any}, payload: {any}", .{ p.pos, p.payload });
            unreachable;
        };

        const bytes = p.payload[p.pos..i];
        p.pos = i + 1;
        return @ptrCast(bytes);
    }

    pub fn skipComptime(p: *PayloadReader, comptime n: usize) void {
        std.debug.assert(p.pos + n <= p.payload.len);
        p.pos += n;
    }

    pub fn finished(p: *const PayloadReader) bool {
        return p.payload.len == p.pos;
    }

    pub fn remained(p: *const PayloadReader) usize {
        return p.payload.len - p.pos;
    }

    pub fn readRefComptime(p: *PayloadReader, comptime n: usize) *const [n]u8 {
        std.debug.assert(p.pos + n <= p.payload.len);
        const bytes = p.payload[p.pos..][0..n];
        p.pos += n;
        return bytes;
    }

    pub fn readRefRuntime(p: *PayloadReader, n: usize) []const u8 {
        std.debug.assert(p.pos + n <= p.payload.len);
        const bytes = p.payload[p.pos .. p.pos + n];
        p.pos += n;
        return bytes;
    }
};

const testing = std.testing;

const TestCapture = struct {
    calls: usize = 0,
    config: ?*const Config = null,
    level: ?logger.Level = null,
    message: [256]u8 = undefined,
    message_len: usize = 0,
};

fn captureLog(context: ?*anyopaque, config: ?*const Config, level: logger.Level, message: []const u8) void {
    const capture: *TestCapture = @ptrCast(@alignCast(context.?));
    capture.calls += 1;
    capture.config = config;
    capture.level = level;
    capture.message_len = @min(message.len, capture.message.len);
    @memcpy(capture.message[0..capture.message_len], message[0..capture.message_len]);
}

test "asError - an error packet is logged through the logger of its config" {
    var capture: TestCapture = .{};
    var config: Config = .{ .logger = .{ .context = &capture, .logFn = captureLog } };

    // ERR packet: header, error code (1048), sql state marker, sql state, message
    const message = "table does not exist";
    var payload: [64]u8 = undefined;
    payload[0] = constants.ERR;
    std.mem.writeInt(u16, payload[1..3], 1048, .little);
    payload[3] = '#';
    @memcpy(payload[4..9], "42S02");
    @memcpy(payload[9..][0..message.len], message);
    const packet: Packet = .{ .sequence_id = 1, .payload = payload[0 .. 9 + message.len], .config = &config };

    try testing.expectEqual(error.ErrorPacket, packet.asError());
    try testing.expectEqual(1, capture.calls);
    try testing.expectEqual(&config, capture.config.?);
    try testing.expectEqual(logger.Level.warn, capture.level.?);
    try testing.expectEqualStrings(
        "error packet: (code: 1048, message: table does not exist)",
        capture.message[0..capture.message_len],
    );
}

test "asError - an unexpected packet is logged through the logger of its config" {
    var capture: TestCapture = .{};
    var config: Config = .{ .logger = .{ .context = &capture, .logFn = captureLog } };

    const packet: Packet = .{ .sequence_id = 1, .payload = &[_]u8{constants.HANDSHAKE_V10}, .config = &config };

    try testing.expectEqual(error.UnexpectedPacket, packet.asError());
    try testing.expectEqual(1, capture.calls);
    try testing.expectEqual(&config, capture.config.?);
    try testing.expectEqual(logger.Level.warn, capture.level.?);
}

test "reader - the payload reader logs through the logger of the packet's config" {
    var capture: TestCapture = .{};
    var config: Config = .{ .logger = .{ .context = &capture, .logFn = captureLog } };

    const packet: Packet = .{ .sequence_id = 0, .payload = "hello\x00", .config = &config };
    var reader = packet.reader();
    try testing.expectEqualStrings("hello", reader.readNullTerminatedString());

    // a payload without a NUL terminator is a bug in the server's answer, but
    // the message still has to reach the logger of the config
    try testing.expectEqual(0, capture.calls);
    try testing.expectEqual(&config, reader.config.?);
}
