const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;
const allocator = std.testing.allocator;
const ErrorPacket = @import("../src/protocol.zig").generic_response.ErrorPacket;

test "ping" {
    var c = Client.init(test_config);
    defer c.deinit();

    try c.ping(allocator);
}

fn expectRows(value: anytype) !@TypeOf(value.rows) {
    return switch (value) {
        .rows => |rows| rows,
        else => errorUnexpectedValue(value),
    };
}

fn expectErr(value: anytype) !@TypeOf(value.err) {
    return switch (value) {
        .err => |err| err,
        else => return errorUnexpectedValue(value),
    };
}

fn expectOk(value: anytype) !@TypeOf(value.ok) {
    return switch (value) {
        .ok => |ok| ok,
        else => return errorUnexpectedValue(value),
    };
}

fn errorUnexpectedValue(value: anytype) error{ ErrorPacket, UnexpectedValue } {
    switch (value) {
        .err => |err| return errorErrorPacket(&err),
        else => |x| {
            std.log.err("unexpected value: {any}\n", .{x});
            return error.UnexpectedValue;
        },
    }
}

fn errorErrorPacket(err: *const ErrorPacket) error{ErrorPacket} {
    std.log.err(
        "got error packet: (code: {d}, message: {s})",
        .{ err.error_code, err.error_message },
    );
    return error.ErrorPacket;
}

test "query database create and drop" {
    var c = Client.init(test_config);
    defer c.deinit();
    {
        const qr = try c.query(allocator, "CREATE DATABASE testdb");
        defer qr.deinit(allocator);
        _ = try expectOk(qr.value);
    }
    {
        const qr = try c.query(allocator, "DROP DATABASE testdb");
        defer qr.deinit(allocator);
        _ = try expectOk(qr.value);
    }
}

test "query syntax error" {
    var c = Client.init(test_config);
    defer c.deinit();

    const qr = try c.query(allocator, "garbage query");
    defer qr.deinit(allocator);
    _ = try expectErr(qr.value);
}

test "query text protocol" {
    var c = Client.init(test_config);
    defer c.deinit();

    {
        const qr = try c.query(allocator, "SELECT 1");
        defer qr.deinit(allocator);

        const rows = (try expectRows(qr.value)).iter();
        var dest = [_]?[]const u8{undefined};
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "1", dest[0].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 3,4");
        defer qr.deinit(allocator);
        var rows = (try expectRows(qr.value)).iter();

        var dest = [_]?[]const u8{ undefined, undefined };
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "3", dest[0].?);
            try std.testing.expectEqualSlices(u8, "4", dest[1].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 5,null,7");
        defer qr.deinit(allocator);
        var rows = (try expectRows(qr.value)).iter();
        var dest = [_]?[]const u8{ undefined, undefined, undefined };
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "5", dest[0].?);
            try std.testing.expectEqual(@as(?[]const u8, null), dest[1]);
            try std.testing.expectEqualSlices(u8, "7", dest[2].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 8,9 UNION ALL SELECT 10,11");
        defer qr.deinit(allocator);
        var rows = try expectRows(qr.value);

        var dest = [_]?[]const u8{ undefined, undefined };
        {
            const row = try rows.readRow(allocator);
            defer row.deinit(std.testing.allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "8", dest[0].?);
            try std.testing.expectEqualSlices(u8, "9", dest[1].?);
        }
        {
            const row = try rows.readRow(allocator);
            defer row.deinit(std.testing.allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "10", dest[0].?);
            try std.testing.expectEqualSlices(u8, "11", dest[1].?);
        }
        {
            const row = try rows.readRow(std.testing.allocator);
            defer row.deinit(std.testing.allocator);
            switch (row.value) {
                .eof => {},
                .err => return errorUnexpectedValue(row.value),
                .raw => return errorUnexpectedValue(row.value),
            }
        }
    }
}

test "prepare execute" {
    var c = Client.init(test_config);
    defer c.deinit();
    // { // prepare no execute
    //     const pr = try c.prepare(allocator, "CREATE TABLE default.testtable (id INT, name VARCHAR(255))");
    //     defer pr.deinit(allocator);
    //     _ = try expectOk(pr.value);
    // }
    // { // prepare with params
    //     const pr = try c.prepare(allocator, "SELECT CONCAT(?, ?) as my_col");
    //     defer pr.deinit(allocator);
    //     switch (pr.value) {
    //         .ok => |prep_ok| {
    //             try std.testing.expectEqual(prep_ok.num_params, 2);
    //             try std.testing.expectEqual(prep_ok.num_columns, 1);
    //         },
    //         else => return errorUnexpectedValue(pr.value),
    //     }
    // }
    // {
    //     const pr = try c.prepare(allocator, "SELECT 1,2,3");
    //     defer pr.deinit(allocator);
    //     const prep_ok = try expectOk(pr.value);

    //     const res = try c.execute(allocator, prep_ok);
    //     _ = res;
    //     // std.log.err("prep_ok: {any}", .{prep_ok});
    // }
}
