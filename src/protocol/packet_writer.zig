const std = @import("std");

pub fn writeUInt8(writer: anytype, v: u8) !void {
    _ = try writer.writeAll(&[_]u8{v});
}

pub fn writeUInt16(writer: anytype, v: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeIntLittle(u16, bytes, v);
    _ = try writer.write(&bytes);
}

pub fn writeUInt24(writer: anytype, v: u24) !void {
    var bytes: [3]u8 = undefined;
    std.mem.writeIntLittle(u24, bytes, v);
    _ = try writer.write(&bytes);
}

pub fn writeUInt32(writer: anytype, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeIntLittle(u32, bytes, v);
    _ = try writer.write(&bytes);
}

pub fn writeUInt64(writer: anytype, v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeIntLittle(u64, bytes, v);
    _ = try writer.write(&bytes);
}

pub fn writeNullTerminatedString(writer: anytype, v: [:0]const u8) !void {
    _ = try writer.write(v[0 .. v.len + 1]);
}

pub fn writeFillers(comptime n: comptime_int, writer: anytype) !void {
    const bytes = [_]u8{0} ** n;
    _ = try writer.write(&bytes);
}

pub fn writeLengthEncodedString(writer: anytype, s: []const u8) !void {
    writeLengthEncodedInteger(writer, @as(u64, s.len));
    _ = try writer.write(s);
}

pub fn writeLengthEncodedInteger(writer: anytype, v: u64) !void {
    if (v < 251) {
        _ = try writeUInt8(writer, @truncate(v));
    } else if (v < 1 << 16) {
        _ = try writeUInt8(writer, 0xFC);
        _ = try writeUInt16(writer, @truncate(v));
    } else if (v < 1 << 24) {
        _ = try writeUInt8(writer, 0xFD);
        _ = try writeUInt24(writer, @truncate(v));
    } else if (v < 1 << 64) {
        _ = try writeUInt8(writer, 0xFE);
        _ = try writeUInt64(writer, v);
    } else {
        std.log.err("Invalid length encoded integer: {any}\n", .{v});
        return error.InvalidLengthEncodedInteger;
    }
}
