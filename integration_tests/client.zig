const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;
const allocator = std.testing.allocator;

test "ping" {
    var c = Client.init(test_config);
    defer c.deinit();

    try c.ping(allocator);
}

test "query database create and drop" {
    var c = Client.init(test_config);
    defer c.deinit();
    {
        const qr = try c.query(allocator, "CREATE DATABASE testdb");
        defer qr.deinit(allocator);
        const a = try qr.ok();
        _ = a;
    }
    {
        const qr = try c.query(allocator, "DROP DATABASE testdb");
        defer qr.deinit(allocator);
        _ = try qr.ok();
    }
}

test "query syntax error" {
    var c = Client.init(test_config);
    defer c.deinit();

    const qr = try c.query(allocator, "garbage query");
    defer qr.deinit(allocator);
    try std.testing.expectError(error.ErrorPacket, qr.ok());
}

test "query text protocol" {
    var c = Client.init(test_config);
    defer c.deinit();

    {
        const qr = try c.query(allocator, "SELECT 1");
        defer qr.deinit(allocator);
        var rows = try qr.rows(allocator);
        defer rows.deinit(allocator);
        var dest = [_]?[]const u8{undefined};
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "1", dest[0].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 2");
        defer qr.deinit(allocator);
        var rows = try qr.rows(allocator);
        defer rows.deinit(allocator);
        var dest = [_]?[]const u8{undefined};
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "2", dest[0].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 3,4");
        defer qr.deinit(allocator);
        var rows = try qr.rows(allocator);
        defer rows.deinit(allocator);
        var dest = [_]?[]const u8{ undefined, undefined };
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "3", dest[0].?);
            try std.testing.expectEqualSlices(u8, "4", dest[1].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 5,null,7");
        defer qr.deinit(allocator);
        var rows = try qr.rows(allocator);
        defer rows.deinit(allocator);
        var dest = [_]?[]const u8{ undefined, undefined, undefined };
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "5", dest[0].?);
            try std.testing.expectEqual(@as(?[]const u8, null), dest[1]);
            try std.testing.expectEqualSlices(u8, "7", dest[2].?);
        }
    }
    {
        const qr = try c.query(allocator, "SELECT 8,9 UNION ALL SELECT 10,11");
        defer qr.deinit(allocator);
        var rows = try qr.rows(allocator);
        defer rows.deinit(allocator);

        var dest = [_]?[]const u8{ undefined, undefined };
        {
            const row = (try rows.next(std.testing.allocator)).?;
            defer row.deinit(std.testing.allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "8", dest[0].?);
            try std.testing.expectEqualSlices(u8, "9", dest[1].?);
        }
        {
            const row = (try rows.next(std.testing.allocator)).?;
            defer row.deinit(std.testing.allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "10", dest[0].?);
            try std.testing.expectEqualSlices(u8, "11", dest[1].?);
        }
        {
            const row = try rows.next(std.testing.allocator);
            try std.testing.expect(row == null);
        }
    }
}

test "prepare" {
    var c = Client.init(test_config);
    defer c.deinit();
    {
        const pr = try c.prepare(allocator, "CREATE TABLE default.testtable (id INT, name VARCHAR(255))");
        defer pr.deinit(allocator);
        _ = try pr.ok();
    }
    {
        const pr = try c.prepare(allocator, "select concat (?, ?) as my_col");
        defer pr.deinit(allocator);
        const prep_ok = try pr.ok();
        try std.testing.expectEqual(prep_ok.num_params, 2);
        try std.testing.expectEqual(prep_ok.num_columns, 1);
    }
}
