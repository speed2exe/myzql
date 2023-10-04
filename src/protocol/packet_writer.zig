const std = @import("std");

pub fn writeUInt16(writer: anytype, v: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeIntLittle(u16, bytes, v);
    try writer.write(&bytes);
}

pub fn writeUInt24(writer: anytype, v: u24) !void {
    var bytes: [3]u8 = undefined;
    std.mem.writeIntLittle(u24, bytes, v);
    try writer.write(&bytes);
}

pub fn writeNullTerminatedString(writer: anytype, v: [:0]const u8) !void {
    try writer.write(v[0 .. v.len + 1]);
}
