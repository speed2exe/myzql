const std = @import("std");
const myzql = @import("myzql");
const Client = myzql.client.Client;
const test_config = @import("./config.zig").test_config;
const allocator = std.testing.allocator;
const ErrorPacket = myzql.protocol.generic_response.ErrorPacket;
const minInt = std.math.minInt;
const maxInt = std.math.maxInt;
const DateTime = myzql.temporal.DateTime;
const Duration = myzql.temporal.Duration;

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
            const data = try row.expect(.data);
            try data.scan(&dest);
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
            const data = try row.expect(.data);
            try data.scan(&dest);
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
            const data = try row.expect(.data);
            try data.scan(&dest);
            try std.testing.expectEqualSlices(u8, "5", dest[0].?);
            try std.testing.expectEqual(@as(?[]const u8, null), dest[1]);
            try std.testing.expectEqualSlices(u8, "7", dest[2].?);
        }
    }
    {
        const query_res = try c.query(allocator, "SELECT 8,9 UNION ALL SELECT 10,11");
        defer query_res.deinit(allocator);
        const rows = try query_res.expect(.rows);

        {
            var dest = [_]?[]const u8{ undefined, undefined };
            const row = try rows.readRow(allocator);
            defer row.deinit(std.testing.allocator);
            const data = try row.expect(.data);
            try data.scan(&dest);
            try std.testing.expectEqualSlices(u8, "8", dest[0].?);
            try std.testing.expectEqualSlices(u8, "9", dest[1].?);
        }
        {
            const row = try rows.readRow(allocator);
            defer row.deinit(std.testing.allocator);
            const data = try row.expect(.data);
            const dest = try data.scanAlloc(allocator);
            defer allocator.free(dest);
            try std.testing.expectEqualSlices(u8, "10", dest[0].?);
            try std.testing.expectEqualSlices(u8, "11", dest[1].?);
        }
        {
            const row = try rows.readRow(std.testing.allocator);
            defer row.deinit(std.testing.allocator);
            switch (row.value) {
                .ok => {},
                .err => |err| return err.asError(),
                .data => @panic("unexpected data"),
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
        const table_texts = try iter.collectTexts(allocator);
        defer table_texts.deinit(allocator);
        try std.testing.expectEqual(table_texts.rows.len, 2);
        {
            const expected: []const ?[]const u8 = &.{ "1", "2", "3", "4", null, "6" };
            try std.testing.expectEqualDeep(expected, table_texts.elems);
        }
        {
            const expected: []const ?[]const u8 = &.{ "1", "2", "3" };
            try std.testing.expectEqualDeep(expected, table_texts.rows[0]);
        }
        {
            const expected: []const ?[]const u8 = &.{ "4", null, "6" };
            try std.testing.expectEqualDeep(expected, table_texts.rows[1]);
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

        while (try rows.next(allocator)) |row| {
            defer row.deinit(allocator);
            {
                var dest: MyType = undefined;
                const data = try row.expect(.data);
                try data.scan(&dest);
                try std.testing.expectEqualDeep(expected, dest);
            }
            {
                const data = try row.expect(.data);
                const dest = try data.scanAlloc(MyType, allocator);
                defer allocator.destroy(dest);
                try std.testing.expectEqualDeep(&expected, dest);
            }
        }
    }
    {
        const query =
            \\SELECT 1, 2, 3
            \\UNION ALL
            \\SELECT 4, 5, 6
        ;
        const prep_res = try c.prepare(allocator, query);
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const query_res = try c.execute(allocator, &prep_stmt, .{});
        defer query_res.deinit(allocator);
        const rows = (try query_res.expect(.rows)).iter();

        const MyType = struct {
            a: u8,
            b: u8,
            c: u8,
        };
        const expected: []const MyType = &.{
            .{ .a = 1, .b = 2, .c = 3 },
            .{ .a = 4, .b = 5, .c = 6 },
        };

        const structs = try rows.collectStructs(MyType, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.rows);
    }
}

test "binary data types - int" {
    var c = Client.init(test_config);
    defer c.deinit();

    try queryExpectOk(&c, "CREATE DATABASE test");
    defer queryExpectOk(&c, "DROP DATABASE test") catch {};

    try queryExpectOk(&c,
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

    { // Insert (Binary Protocol)
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
    }

    { // Select (Text Protocol)
        const res = try c.query(allocator, "SELECT * FROM test.int_types_example");
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const table_texts = try rows_iter.collectTexts(allocator);
        defer table_texts.deinit(allocator);

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
        try std.testing.expectEqualDeep(expected, table_texts.rows);
    }

    { // Select (Binary Protocol)
        const IntTypesExample = struct {
            tinyint_col: ?i8,
            smallint_col: ?i16,
            mediumint_col: ?i24,
            int_col: ?i32,
            bigint_col: ?i64,
            tinyint_unsigned_col: ?u8,
            smallint_unsigned_col: ?u16,
            mediumint_unsigned_col: ?u24,
            int_unsigned_col: ?u32,
            bigint_unsigned_col: ?u64,
        };

        const prep_res = try c.prepare(allocator, "SELECT * FROM test.int_types_example LIMIT 4");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const res = try c.execute(allocator, &prep_stmt, .{});
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const expected: []const IntTypesExample = &.{
            .{
                .tinyint_col = 0,
                .smallint_col = 0,
                .mediumint_col = 0,
                .int_col = 0,
                .bigint_col = 0,
                .tinyint_unsigned_col = 0,
                .smallint_unsigned_col = 0,
                .mediumint_unsigned_col = 0,
                .int_unsigned_col = 0,
                .bigint_unsigned_col = 0,
            },
            .{
                .tinyint_col = -128,
                .smallint_col = -32768,
                .mediumint_col = -8388608,
                .int_col = -2147483648,
                .bigint_col = -9223372036854775808,
                .tinyint_unsigned_col = 0,
                .smallint_unsigned_col = 0,
                .mediumint_unsigned_col = 0,
                .int_unsigned_col = 0,
                .bigint_unsigned_col = 0,
            },
            .{
                .tinyint_col = 127,
                .smallint_col = 32767,
                .mediumint_col = 8388607,
                .int_col = 2147483647,
                .bigint_col = 9223372036854775807,
                .tinyint_unsigned_col = 255,
                .smallint_unsigned_col = 65535,
                .mediumint_unsigned_col = 16777215,
                .int_unsigned_col = 4294967295,
                .bigint_unsigned_col = 18446744073709551615,
            },
            .{
                .tinyint_col = null,
                .smallint_col = null,
                .mediumint_col = null,
                .int_col = null,
                .bigint_col = null,
                .tinyint_unsigned_col = null,
                .smallint_unsigned_col = null,
                .mediumint_unsigned_col = null,
                .int_unsigned_col = null,
                .bigint_unsigned_col = null,
            },
        };

        const structs = try rows_iter.collectStructs(IntTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.rows);
    }
}

test "binary data types - float" {
    var c = Client.init(test_config);
    defer c.deinit();

    try queryExpectOk(&c, "CREATE DATABASE test");
    defer queryExpectOk(&c, "DROP DATABASE test") catch {};

    try queryExpectOk(&c,
        \\CREATE TABLE test.float_types_example (
        \\    float_col FLOAT,
        \\    double_col DOUBLE
        \\)
    );
    defer queryExpectOk(&c, "DROP TABLE test.float_types_example") catch {};

    { // Exec Insert
        const prep_res = try c.prepare(allocator, "INSERT INTO test.float_types_example VALUES (?, ?)");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);

        const params = .{
            .{ 0.0, 0.0 },
            .{ -1.23, -1.23 },
            .{ 1.23, 1.23 },
            .{ null, null },
            .{ @as(?f32, 0), @as(?f64, 0) },
            .{ @as(f32, -1.23), @as(f64, -1.23) },
            .{ @as(f32, 1.23), @as(f64, 1.23) },
            .{ @as(?f32, null), @as(?f64, null) },
        };
        inline for (params) |param| {
            const exe_res = try c.execute(allocator, &prep_stmt, param);
            defer exe_res.deinit(allocator);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Text Protocol
        const res = try c.query(allocator, "SELECT * FROM test.float_types_example");
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const table_texts = try rows_iter.collectTexts(allocator);
        defer table_texts.deinit(allocator);

        const expected: []const []const ?[]const u8 = &.{
            &.{ "0", "0" },
            &.{ "-1.23", "-1.23" },
            &.{ "1.23", "1.23" },
            &.{ null, null },
            &.{ "0", "0" },
            &.{ "-1.23", "-1.23" },
            &.{ "1.23", "1.23" },
            &.{ null, null },
        };
        try std.testing.expectEqualDeep(expected, table_texts.rows);
    }

    { // Select (Binary Protocol)
        const FloatTypesExample = struct {
            float_col: f32,
            double_col: f64,
        };

        const prep_res = try c.prepare(allocator, "SELECT * FROM test.float_types_example LIMIT 3");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const res = try c.execute(allocator, &prep_stmt, .{});
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const expected: []const FloatTypesExample = &.{
            .{ .float_col = 0, .double_col = 0 },
            .{ .float_col = -1.23, .double_col = -1.23 },
            .{ .float_col = 1.23, .double_col = 1.23 },
        };

        const structs = try rows_iter.collectStructs(FloatTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.rows);
    }
}

test "binary data types - string" {
    var c = Client.init(test_config);
    defer c.deinit();

    try queryExpectOk(&c, "CREATE DATABASE test");
    defer queryExpectOk(&c, "DROP DATABASE test") catch {};

    try queryExpectOk(&c,
        \\CREATE TABLE test.string_types_example (
        \\    varchar_col VARCHAR(255),
        \\    not_null_varchar_col VARCHAR(255) NOT NULL,
        \\    enum_col ENUM('a', 'b', 'c'),
        \\    not_null_enum_col ENUM('a', 'b', 'c') NOT NULL
        \\)
    );
    defer queryExpectOk(&c, "DROP TABLE test.string_types_example") catch {};

    const MyEnum = enum { a, b, c };

    { // Exec Insert
        const prep_res = try c.prepare(allocator, "INSERT INTO test.string_types_example VALUES (?, ?, ?, ?)");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);

        const params = .{
            .{ "hello", "world", "a", @as([*c]const u8, "b") },
            .{ null, "foo", null, "c" },
            .{ null, "", null, "a" },
            .{
                @as(?*const [3]u8, "baz"),
                @as([*:0]const u8, "bar"),
                @as(?[]const u8, null),
                @as(MyEnum, .c),
            },
        };
        inline for (params) |param| {
            const exe_res = try c.execute(allocator, &prep_stmt, param);
            defer exe_res.deinit(allocator);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Text Protocol
        const res = try c.query(allocator, "SELECT * FROM test.string_types_example");
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const table_texts = try rows_iter.collectTexts(allocator);
        defer table_texts.deinit(allocator);

        const expected: []const []const ?[]const u8 = &.{
            &.{ "hello", "world", "a", "b" },
            &.{ null, "foo", null, "c" },
            &.{ null, "", null, "a" },
            &.{ "baz", "bar", null, "c" },
        };
        try std.testing.expectEqualDeep(expected, table_texts.rows);
    }

    { // Select (Binary Protocol)
        const StringTypesExample = struct {
            varchar_col: ?[]const u8,
            not_null_varchar_col: []const u8,
            not_null_enum_col: []const u8,
            not_null_enum_col_2: MyEnum,
        };

        const prep_res = try c.prepare(allocator,
            \\SELECT
            \\    varchar_col,
            \\    not_null_varchar_col,
            \\    not_null_enum_col,
            \\    not_null_enum_col
            \\FROM test.string_types_example LIMIT 1
        );
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const res = try c.execute(allocator, &prep_stmt, .{});
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const expected: []const StringTypesExample = &.{
            .{
                .varchar_col = "hello",
                .not_null_varchar_col = "world",
                .not_null_enum_col = "b",
                .not_null_enum_col_2 = .b,
            },
        };

        const structs = try rows_iter.collectStructs(StringTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.rows);
    }
}

test "binary data types - temporal" {
    var c = Client.init(test_config);
    defer c.deinit();

    try queryExpectOk(&c, "CREATE DATABASE test");
    defer queryExpectOk(&c, "DROP DATABASE test") catch {};

    try queryExpectOk(&c,
        \\CREATE TABLE test.temporal_types_example (
        \\    event_time DATETIME(6) NOT NULL,
        \\    event_time2 DATETIME(2) NOT NULL,
        \\    event_time3 DATETIME NOT NULL,
        \\    duration TIME(6) NOT NULL,
        \\    duration2 TIME(4) NOT NULL,
        \\    duration3 TIME NOT NULL
        \\)
    );
    defer queryExpectOk(&c, "DROP TABLE test.temporal_types_example") catch {};

    { // Exec Insert
        const prep_res = try c.prepare(allocator, "INSERT INTO test.temporal_types_example VALUES (?, ?, ?, ?, ?, ?)");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);

        const my_time: DateTime = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58, .microsecond = 123456 };
        const datetime_no_ms: DateTime = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 };
        const only_day: DateTime = .{ .year = 2023, .month = 11, .day = 30 };
        const my_duration: Duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59, .microseconds = 123456 };
        const duration_no_ms: Duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59 };
        const duration_zero: Duration = .{};

        const params = .{
            .{ my_time, my_time, my_time, my_duration, my_duration, my_duration },
            .{ datetime_no_ms, datetime_no_ms, datetime_no_ms, duration_no_ms, duration_no_ms, duration_no_ms },
            .{ only_day, only_day, only_day, duration_zero, duration_zero, duration_zero },
        };

        inline for (params) |param| {
            const exe_res = try c.execute(allocator, &prep_stmt, param);
            defer exe_res.deinit(allocator);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Text Protocol
        const res = try c.query(allocator, "SELECT * FROM test.temporal_types_example");
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const table_texts = try rows_iter.collectTexts(allocator);
        defer table_texts.deinit(allocator);

        const expected: []const []const ?[]const u8 = &.{
            &.{ "2023-11-30 06:50:58.123456", "2023-11-30 06:50:58.12", "2023-11-30 06:50:58", "47:59:59.123456", "47:59:59.1235", "47:59:59" },
            &.{ "2023-11-30 06:50:58.000000", "2023-11-30 06:50:58.00", "2023-11-30 06:50:58", "47:59:59.000000", "47:59:59.0000", "47:59:59" },
            &.{ "2023-11-30 00:00:00.000000", "2023-11-30 00:00:00.00", "2023-11-30 00:00:00", "00:00:00.000000", "00:00:00.0000", "00:00:00" },
        };

        try std.testing.expectEqualDeep(expected, table_texts.rows);
    }

    { // Select (Binary Protocol)
        const TemporalTypesExample = struct {
            event_time: DateTime,
            event_time2: DateTime,
            event_time3: DateTime,
            duration: Duration,
            duration2: Duration,
            duration3: Duration,
        };
        const prep_res = try c.prepare(allocator, "SELECT * FROM test.temporal_types_example LIMIT 3");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const res = try c.execute(allocator, &prep_stmt, .{});
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const expected: []const TemporalTypesExample = &.{
            .{
                .event_time = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58, .microsecond = 123456 },
                .event_time2 = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58, .microsecond = 120000 },
                .event_time3 = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 },
                .duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59, .microseconds = 123456 },
                .duration2 = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59, .microseconds = 123500 },
                .duration3 = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59 },
            },
            .{
                .event_time = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 },
                .event_time2 = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 },
                .event_time3 = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 },
                .duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59 },
                .duration2 = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59 },
                .duration3 = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59 },
            },
            .{
                .event_time = .{ .year = 2023, .month = 11, .day = 30 },
                .event_time2 = .{ .year = 2023, .month = 11, .day = 30 },
                .event_time3 = .{ .year = 2023, .month = 11, .day = 30 },
                .duration = .{},
                .duration2 = .{},
                .duration3 = .{},
            },
        };

        const structs = try rows_iter.collectStructs(TemporalTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.rows);
    }
}

test "select concat with params" {
    var c = Client.init(test_config);
    defer c.deinit();

    { // Select (Binary Protocol)
        const prep_res = try c.prepare(allocator, "SELECT CONCAT(?, ?) AS col1");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);
        const res = try c.execute(allocator, &prep_stmt, .{ "hello", "world" });
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const Result = struct { col1: []const u8 };
        const expected: []const Result = &.{.{ .col1 = "helloworld" }};
        const structs = try rows_iter.collectStructs(Result, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.rows);
    }
}
