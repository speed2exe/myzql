const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;

test "ping" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    try c.ping();
}

test "query database create and drop" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    _ = @field(try c.query("CREATE DATABASE testdb"), "ok");
    _ = @field(try c.query("DROP DATABASE testdb"), "ok");
}

test "query syntax error" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    _ = @field(try c.query("garbage query"), "err");
}

test "query text protocol" {
    var c = Client.init(test_config, std.testing.allocator);
    defer c.deinit();

    {
        const qr = try c.query("SELECT 1");
        var rows = qr.rows;
        defer rows.deinit(std.testing.allocator);
        var dest = [_]?[]const u8{undefined};
        while (try rows.next(std.testing.allocator)) |row| {
            defer row.deinit(std.testing.allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "1", dest[0].?);
        }
    }
    {
        const qr = try c.query("SELECT 2");
        var rows = qr.rows;
        defer rows.deinit(std.testing.allocator);
        var dest = [_]?[]const u8{undefined};
        while (try rows.next(std.testing.allocator)) |row| {
            defer row.deinit(std.testing.allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "2", dest[0].?);
        }
    }
    {
        const qr = try c.query("SELECT 3,4");
        var rows = qr.rows;
        defer rows.deinit(std.testing.allocator);
        var dest = [_]?[]const u8{ undefined, undefined };
        while (try rows.next(std.testing.allocator)) |row| {
            defer row.deinit(std.testing.allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "3", dest[0].?);
            try std.testing.expectEqualSlices(u8, "4", dest[1].?);
        }
    }
    {
        const qr = try c.query("SELECT 5,null,7");
        var rows = qr.rows;
        defer rows.deinit(std.testing.allocator);
        var dest = [_]?[]const u8{ undefined, undefined, undefined };
        while (try rows.next(std.testing.allocator)) |row| {
            defer row.deinit(std.testing.allocator);
            row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "5", dest[0].?);
            try std.testing.expectEqual(@as(?[]const u8, null), dest[1]);
            try std.testing.expectEqualSlices(u8, "7", dest[2].?);
        }
    }
    {
        const qr = try c.query("SELECT 8,9 UNION ALL SELECT 10,11");
        var rows = qr.rows;
        defer rows.deinit(std.testing.allocator);

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
