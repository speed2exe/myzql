const std = @import("std");
const Client = @import("../src/client.zig").Client;
const test_config = @import("./config.zig").test_config;
const allocator = std.testing.allocator;
const ErrorPacket = @import("../src/protocol.zig").generic_response.ErrorPacket;
const minInt = std.math.minInt;
const maxInt = std.math.maxInt;

// convenient function for testing
fn queryExpectOk(c: *Client, query: []const u8) !void {
    const query_res = try c.query(allocator, query);
    defer query_res.deinit(allocator);
    _ = try query_res.expect(.ok);
}

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
        _ = try qr.expect(.ok);
    }
    {
        const qr = try c.query(allocator, "DROP DATABASE testdb");
        defer qr.deinit(allocator);
        _ = try qr.expect(.ok);
    }
}

test "query syntax error" {
    var c = Client.init(test_config);
    defer c.deinit();

    const qr = try c.query(allocator, "garbage query");
    defer qr.deinit(allocator);
    _ = try qr.expect(.err);
}

test "query text protocol" {
    var c = Client.init(test_config);
    defer c.deinit();

    {
        const query_res = try c.query(allocator, "SELECT 1");
        defer query_res.deinit(allocator);

        const rows = (try query_res.expect(.rows)).iter();
        var dest = [_]?[]const u8{undefined};
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "1", dest[0].?);
        }
    }
    {
        const query_res = try c.query(allocator, "SELECT 3,4");
        defer query_res.deinit(allocator);
        const rows = (try query_res.expect(.rows)).iter();

        var dest = [_]?[]const u8{ undefined, undefined };
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            try row.scan(&dest);
            try std.testing.expectEqualSlices(u8, "3", dest[0].?);
            try std.testing.expectEqualSlices(u8, "4", dest[1].?);
        }
    }
    {
        const query_res = try c.query(allocator, "SELECT 5,null,7");
        defer query_res.deinit(allocator);
        const rows = (try query_res.expect(.rows)).iter();
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
        const query_res = try c.query(allocator, "SELECT 8,9 UNION ALL SELECT 10,11");
        defer query_res.deinit(allocator);
        const rows = try query_res.expect(.rows);

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
                .err => |err| return err.asError(),
                .raw => @panic("unexpected raw"),
            }
        }
    }
}

test "query text table" {
    var c = Client.init(test_config);
    defer c.deinit();

    {
        const query_res = try c.query(allocator, "SELECT 1,2,3 UNION ALL SELECT 4,null,6");
        defer query_res.deinit(allocator);
        const iter = (try query_res.expect(.rows)).iter();
        const table = try iter.collect(allocator);
        defer table.deinit(allocator);
        try std.testing.expectEqual(table.rows.len, 2);
        {
            var expected = [_]?[]const u8{ "1", "2", "3", "4", null, "6" };
            try std.testing.expectEqualDeep(@as([]?[]const u8, &expected), table.elems);
        }
        {
            var expected = [_]?[]const u8{ "1", "2", "3" };
            try std.testing.expectEqualDeep(@as([]?[]const u8, &expected), table.rows[0]);
        }
        {
            var expected = [_]?[]const u8{ "4", null, "6" };
            try std.testing.expectEqualDeep(@as([]?[]const u8, &expected), table.rows[1]);
        }
    }
}

test "prepare check" {
    var c = Client.init(test_config);
    defer c.deinit();
    { // prepare no execute
        const prep_res = try c.prepare(allocator, "CREATE TABLE default.testtable (id INT, name VARCHAR(255))");
        defer prep_res.deinit(allocator);
        _ = try prep_res.expect(.ok);
    }
    { // prepare with params
        const prep_res = try c.prepare(allocator, "SELECT CONCAT(?, ?) as my_col");
        defer prep_res.deinit(allocator);

        switch (prep_res.value) {
            .ok => |prep_stmt| {
                try std.testing.expectEqual(prep_stmt.prep_ok.num_params, 2);
                try std.testing.expectEqual(prep_stmt.prep_ok.num_columns, 1);
            },
            .err => |err| return err.asError(),
        }
        try std.testing.expectEqual(c.conn.reader.pos, c.conn.reader.len);
    }
}

test "prepare execute - 1" {
    var c = Client.init(test_config);
    defer c.deinit();
    {
        const prep_res = try c.prepare(allocator, "CREATE DATABASE testdb2");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const query_res = try c.execute(allocator, &prep_stmt, .{});
        defer query_res.deinit(allocator);
        _ = try query_res.expect(.ok);
    }
    {
        const prep_res = try c.prepare(allocator, "DROP DATABASE testdb2");
        defer prep_res.deinit(allocator);
        const prep_ok = try prep_res.expect(.ok);
        const query_res = try c.execute(allocator, &prep_ok, .{});
        defer query_res.deinit(allocator);
        _ = try query_res.expect(.ok);
    }
}

test "prepare execute - 2" {
    var c = Client.init(test_config);
    defer c.deinit();

    const prep_res_1 = try c.prepare(allocator, "CREATE DATABASE testdb3");
    defer prep_res_1.deinit(allocator);
    const prep_stmt_1 = try prep_res_1.expect(.ok);

    const prep_res_2 = try c.prepare(allocator, "DROP DATABASE testdb3");
    defer prep_res_2.deinit(allocator);
    const prep_stmt_2 = try prep_res_2.expect(.ok);

    {
        const query_res = try c.execute(allocator, &prep_stmt_1, .{});
        defer query_res.deinit(allocator);
        _ = try query_res.expect(.ok);
    }
    {
        const query_res = try c.execute(allocator, &prep_stmt_2, .{});
        defer query_res.deinit(allocator);
        _ = try query_res.expect(.ok);
    }
}

test "prepare execute with result" {
    var c = Client.init(test_config);
    defer c.deinit();

    {
        const query =
            \\SELECT null, "hello", 3
        ;
        const prep_res = try c.prepare(allocator, query);
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const query_res = try c.execute(allocator, &prep_stmt, .{});
        defer query_res.deinit(allocator);
        const rows = (try query_res.expect(.rows)).iter();

        const MyType = struct {
            a: ?u8,
            b: []const u8,
            c: ?u8,
        };
        const expected = MyType{
            .a = null,
            .b = "hello",
            .c = 3,
        };

        var dest: MyType = undefined;
        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            try row.scanStruct(&dest);
            try std.testing.expectEqualDeep(expected, dest);
        }
    }
}

test "binary data types" {
    var c = Client.init(test_config);
    defer c.deinit();

    try queryExpectOk(&c, "CREATE DATABASE test");
    defer queryExpectOk(&c, "DROP DATABASE test") catch {};

    try queryExpectOk(&c,
        \\
        \\CREATE TABLE test.int_types_example (
        \\    tinyint_col TINYINT,
        \\    smallint_col SMALLINT,
        \\    mediumint_col MEDIUMINT,
        \\    int_col INT,
        \\    bigint_col BIGINT,
        \\    tinyint_unsigned_col TINYINT UNSIGNED,
        \\    smallint_unsigned_col SMALLINT UNSIGNED,
        \\    mediumint_unsigned_col MEDIUMINT UNSIGNED,
        \\    int_unsigned_col INT UNSIGNED,
        \\    bigint_unsigned_col BIGINT UNSIGNED
        \\)
    );
    defer queryExpectOk(&c, "DROP TABLE test.int_types_example") catch {};

    const prep_res = try c.prepare(
        allocator,
        "INSERT INTO test.int_types_example VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer prep_res.deinit(allocator);
    const prep_stmt = try prep_res.expect(.ok);

    const params = .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ -(1 << 7), -(1 << 15), -(1 << 23), -(1 << 31), -(1 << 63), 0, 0, 0, 0, 0 },
        .{ (1 << 7) - 1, (1 << 15) - 1, (1 << 23) - 1, (1 << 31) - 1, (1 << 63) - 1, (1 << 8) - 1, (1 << 16) - 1, (1 << 24) - 1, (1 << 32) - 1, (1 << 64) - 1 },
        .{ null, null, null, null, null, null, null, null, null, null },
        .{ @as(?i8, 0), @as(?i16, 0), @as(?i32, 0), @as(?i64, 0), @as(?u8, 0), @as(?u16, 0), @as(?u32, 0), @as(?u64, 0), @as(?u8, 0), @as(?u64, 0) },
        .{ minInt(i8), minInt(i16), minInt(i24), minInt(i32), minInt(i64), minInt(u8), minInt(u16), minInt(u24), minInt(u32), minInt(u64) },
        .{ maxInt(i8), maxInt(i16), maxInt(i24), maxInt(i32), maxInt(i64), maxInt(u8), maxInt(u16), maxInt(u24), maxInt(u32), maxInt(u64) },
        .{ @as(?i8, null), @as(?i16, null), @as(?i32, null), @as(?i64, null), @as(?u8, null), @as(?u16, null), @as(?u32, null), @as(?u64, null), @as(?u8, null), @as(?u64, null) },
    };
    inline for (params) |param| {
        const exe_res = try c.execute(allocator, &prep_stmt, param);
        defer exe_res.deinit(allocator);
        _ = try exe_res.expect(.ok);
    }

    {
        const res = try c.query(allocator, "SELECT * FROM test.int_types_example");
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const table = try rows_iter.collect(allocator);
        defer table.deinit(allocator);

        const expected: []const []const ?[]const u8 = &.{
            &.{ "0", "0", "0", "0", "0", "0", "0", "0", "0", "0" },
            &.{ "-128", "-32768", "-8388608", "-2147483648", "-9223372036854775808", "0", "0", "0", "0", "0" },
            &.{ "127", "32767", "8388607", "2147483647", "9223372036854775807", "255", "65535", "16777215", "4294967295", "18446744073709551615" },
            &.{ null, null, null, null, null, null, null, null, null, null },
            &.{ "0", "0", "0", "0", "0", "0", "0", "0", "0", "0" },
            &.{ "-128", "-32768", "-8388608", "-2147483648", "-9223372036854775808", "0", "0", "0", "0", "0" },
            &.{ "127", "32767", "8388607", "2147483647", "9223372036854775807", "255", "65535", "16777215", "4294967295", "18446744073709551615" },
            &.{ null, null, null, null, null, null, null, null, null, null },
        };
        try std.testing.expectEqualDeep(expected, table.rows);
    }
}

//
//// SELECT CONCAT(?, ?) AS col1
