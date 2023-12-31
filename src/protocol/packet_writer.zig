const std = @import("std");

pub fn writeUInt8(writer: anytype, v: u8) !void {
    _ = try writer.write(&[_]u8{v});
}

pub fn writeUInt16(writer: anytype, v: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, v, .little);
    try writer.write(&bytes);
}

pub fn writeUInt24(writer: anytype, v: u24) !void {
    var bytes: [3]u8 = undefined;
    std.mem.writeInt(u24, &bytes, v, .little);
    try writer.write(&bytes);
}

pub fn writeUInt32(writer: anytype, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    try writer.write(&bytes);
}

pub fn writeUInt64(writer: anytype, v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    try writer.write(&bytes);
}

pub fn writeNullTerminatedString(writer: anytype, v: [:0]const u8) !void {
    try writer.write(v[0 .. v.len + 1]);
}

pub fn writeFillers(comptime n: comptime_int, writer: anytype) !void {
    const bytes = [_]u8{0} ** n;
    try writer.write(&bytes);
}

pub fn writeLengthEncodedString(writer: anytype, s: []const u8) !void {
    try writeLengthEncodedInteger(writer, s.len);
    try writer.write(s);
}

pub fn writeLengthEncodedInteger(writer: anytype, v: u64) !void {
    if (v < 251) {
        try writeUInt8(writer, @truncate(v));
    } else if (v < 1 << 16) {
        try writeUInt8(writer, 0xFC);
        try writeUInt16(writer, @truncate(v));
    } else if (v < 1 << 24) {
        try writeUInt8(writer, 0xFD);
        try writeUInt24(writer, @truncate(v));
    } else if (v < 1 << 64) {
        try writeUInt8(writer, 0xFE);
        try writeUInt64(writer, v);
    } else {
        std.log.warn("Invalid length encoded integer: {any}\n", .{v});
        return error.InvalidLengthEncodedInteger;
    }
}

pub fn lengthEncodedStringPayloadSize(str_len: usize) u24 {
    var str_len_24: u24 = @truncate(str_len);
    if (str_len < 251) {
        str_len_24 += 1;
    } else if (str_len < 1 << 16) {
        str_len_24 += 3;
    } else if (str_len < 1 << 24) {
        str_len_24 += 4;
    } else if (str_len < 1 << 64) {
        str_len_24 += 9;
    } else unreachable;
    return str_len_24;
}

pub fn lengthEncodedIntegerPayloadSize(v: u64) u24 {
    if (v < 251) {
        return 1;
    } else if (v < 1 << 16) {
        return 3;
    } else if (v < 1 << 24) {
        return 4;
    } else if (v < 1 << 64) {
        return 9;
    } else unreachable;
}
