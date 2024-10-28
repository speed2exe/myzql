const std = @import("std");
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;
const test_config = @import("./config.zig").test_config;
const test_config_with_db = @import("./config.zig").test_config_with_db;
const allocator = std.testing.allocator;
const ErrorPacket = myzql.protocol.generic_response.ErrorPacket;
const minInt = std.math.minInt;
const maxInt = std.math.maxInt;
const DateTime = myzql.temporal.DateTime;
const Duration = myzql.temporal.Duration;
const ResultSet = myzql.result.ResultSet;
const ResultRow = myzql.result.ResultRow;
const BinaryResultRow = myzql.result.BinaryResultRow;
const ResultRowIter = myzql.result.ResultRowIter;
const TextResultRow = myzql.result.TextResultRow;
const TextElemIter = myzql.result.TextElemIter;
const TextElems = myzql.result.TextElems;
const PreparedStatement = myzql.result.PreparedStatement;

// convenient function for testing
fn queryExpectOk(c: *Conn, query: []const u8) !void {
    const query_res = try c.query(query);
    _ = try query_res.expect(.ok);
}

fn queryExpectOkLogError(c: *Conn, query: []const u8) void {
    queryExpectOk(c, query) catch |err| {
        std.debug.print("Error: {}\n", .{err});
    };
}

test "ping" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();
    try c.ping();
}

test "connect with database" {
    var c = try Conn.init(std.testing.allocator, &test_config_with_db);
    defer c.deinit();
    try c.ping();
}

test "query database create and drop" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();
    try queryExpectOk(&c, "CREATE DATABASE testdb");
    try queryExpectOk(&c, "DROP DATABASE testdb");
}

test "query syntax error" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();

    const qr = try c.query("garbage query");
    _ = try qr.expect(.err);
}

test "query text protocol" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();

    { // Iterating over rows and elements
        const query_res = try c.queryRows("SELECT 1");

        const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
        const rows_iter: ResultRowIter(TextResultRow) = rows.iter();
        while (try rows_iter.next()) |row| { // ResultRow(TextResultRow)
            var elems_iter: TextElemIter = row.iter();
            while (elems_iter.next()) |elem| { // ?[] const u8
                try std.testing.expectEqualDeep(@as(?[]const u8, "1"), elem);
            }
        }
    }
    // { // Iterating over rows, collecting elements into []const ?[]const u8
    //     const query_res = try c.queryRows("SELECT 3, 4, null, 6, 7");
    //     const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
    //     const rows_iter: ResultRowIter(TextResultRow) = rows.iter();
    //     while (try rows_iter.next()) |row| {
    //         const elems: TextElems = try row.textElems(allocator);
    //         defer elems.deinit(allocator);

    //         try std.testing.expectEqualDeep(
    //             @as([]const ?[]const u8, &.{ "3", "4", null, "6", "7" }),
    //             elems.elems,
    //         );
    //     }
    // }
    // { // Iterating over rows, collecting elements into []const []const ?[]const u8
    //     const query_res = try c.queryRows("SELECT 8,9 UNION ALL SELECT 10,11");
    //     const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
    //     const table = try rows.tableTexts(allocator);
    //     defer table.deinit(allocator);

    //     try std.testing.expectEqualDeep(
    //         @as([]const []const ?[]const u8, &.{
    //             &.{ "8", "9" },
    //             &.{ "10", "11" },
    //         }),
    //         table.table,
    //     );
    // }
}

test "prepare check" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();
    { // prepare no execute
        const prep_res = try c.prepare(allocator, "CREATE TABLE default.testtable (id INT, name VARCHAR(255))");
        defer prep_res.deinit(allocator);
        _ = try prep_res.expect(.stmt);
    }
    { // prepare with params
        const prep_res = try c.prepare(allocator, "SELECT CONCAT(?, ?) as my_col");
        defer prep_res.deinit(allocator);

        switch (prep_res) {
            .stmt => |prep_stmt| {
                try std.testing.expectEqual(prep_stmt.prep_ok.num_params, 2);
                try std.testing.expectEqual(prep_stmt.prep_ok.num_columns, 1);
            },
            .err => |err| return err.asError(),
        }
        try std.testing.expectEqual(c.reader.len, c.reader.pos);
    }
}

test "prepare execute - 1" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();
    {
        const prep_res = try c.prepare(allocator, "CREATE DATABASE testdb");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const query_res = try c.execute(&prep_stmt, .{});
        _ = try query_res.expect(.ok);
    }
    {
        const prep_res = try c.prepare(allocator, "DROP DATABASE testdb");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const query_res = try c.execute(&prep_stmt, .{});
        _ = try query_res.expect(.ok);
    }
}

test "prepare execute - 2" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();

    const prep_res_1 = try c.prepare(allocator, "CREATE DATABASE testdb");
    defer prep_res_1.deinit(allocator);
    const prep_stmt_1: PreparedStatement = try prep_res_1.expect(.stmt);

    const prep_res_2 = try c.prepare(allocator, "DROP DATABASE testdb");
    defer prep_res_2.deinit(allocator);
    const prep_stmt_2: PreparedStatement = try prep_res_2.expect(.stmt);

    {
        const query_res = try c.execute(&prep_stmt_1, .{});
        _ = try query_res.expect(.ok);
    }
    {
        const query_res = try c.execute(&prep_stmt_2, .{});
        _ = try query_res.expect(.ok);
    }
}

test "prepare execute with result" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();

    {
        const query =
            \\SELECT null, "hello", 3
        ;
        const prep_res = try c.prepare(allocator, query);
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const query_res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);

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

        const rows_iter = rows.iter();

        var dest_ptr: *MyType = undefined;
        while (try rows_iter.next()) |row| {
            {
                var dest: MyType = undefined;
                try row.scan(&dest);
                try std.testing.expectEqualDeep(expected, dest);
            }
            {
                dest_ptr = try row.structCreate(MyType, allocator);
                try std.testing.expectEqualDeep(expected, dest_ptr.*);
            }
        }
        defer BinaryResultRow.structDestroy(dest_ptr, allocator);

        { // Dummy query to test for invalid memory reuse
            const query_res2 = try c.queryRows("SELECT 3, 4, null, 6, 7");

            const rows2: ResultSet(TextResultRow) = try query_res2.expect(.rows);
            const rows_iter2: ResultRowIter(TextResultRow) = rows2.iter();
            while (try rows_iter2.next()) |row| {
                _ = row;
            }
        }

        try std.testing.expectEqualDeep(dest_ptr.b, "hello");
    }
    {
        const query =
            \\SELECT 1, 2, 3
            \\UNION ALL
            \\SELECT 4, 5, 6
        ;
        const prep_res = try c.prepare(allocator, query);
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const query_res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
        const rows_iter = rows.iter();

        const MyType = struct {
            a: u8,
            b: u8,
            c: u8,
        };
        const expected: []const MyType = &.{
            .{ .a = 1, .b = 2, .c = 3 },
            .{ .a = 4, .b = 5, .c = 6 },
        };

        const structs = try rows_iter.tableStructs(MyType, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.struct_list.items);
    }
}

test "binary data types - int" {
    var c = try Conn.init(std.testing.allocator, &test_config);
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
        const prep_stmt = try prep_res.expect(.stmt);

        const params = .{
            .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ -(1 << 7), -(1 << 15), -(1 << 23), -(1 << 31), -(1 << 63), 0, 0, 0, 0, 0 },
            .{ (1 << 7) - 1, (1 << 15) - 1, (1 << 23) - 1, (1 << 31) - 1, (1 << 63) - 1, (1 << 8) - 1, (1 << 16) - 1, (1 << 24) - 1, (1 << 32) - 1, (1 << 64) - 1 },
            .{ null, null, null, null, null, null, null, null, null, null },
            .{ @as(?i8, 0), @as(?i16, 0), @as(?i32, 0), @as(?i64, 0), @as(?u8, 0), @as(?u16, 0), @as(?u32, 0), @as(?u64, 0), @as(?u8, 0), @as(?u64, 0) },
            .{ @as(i8, minInt(i8)), @as(i16, minInt(i16)), @as(i32, minInt(i24)), @as(i32, minInt(i32)), @as(i64, minInt(i64)), @as(u8, minInt(u8)), @as(u16, minInt(u16)), @as(u32, minInt(u24)), @as(u32, minInt(u32)), @as(u64, minInt(u64)) },
            .{ @as(i8, maxInt(i8)), @as(i16, maxInt(i16)), @as(i32, maxInt(i24)), @as(i32, maxInt(i32)), @as(i64, maxInt(i64)), @as(u8, maxInt(u8)), @as(u16, maxInt(u16)), @as(u32, maxInt(u24)), @as(u32, maxInt(u32)), @as(u64, maxInt(u64)) },
            .{ @as(?i8, null), @as(?i16, null), @as(?i32, null), @as(?i64, null), @as(?u8, null), @as(?u16, null), @as(?u32, null), @as(?u64, null), @as(?u8, null), @as(?u64, null) },
        };
        inline for (params) |param| {
            const exe_res = try c.execute(&prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Select (Text Protocol)
        const res = try c.queryRows("SELECT * FROM test.int_types_example");
        const rows: ResultSet(TextResultRow) = try res.expect(.rows);

        const table_texts = try rows.tableTexts(allocator);
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
        try std.testing.expectEqualDeep(expected, table_texts.table);
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
        const prep_stmt = try prep_res.expect(.stmt);
        const res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);

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

        const structs = try rows.iter().tableStructs(IntTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.struct_list.items);
    }
}

test "binary data types - float" {
    var c = try Conn.init(std.testing.allocator, &test_config);
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
        const prep_stmt = try prep_res.expect(.stmt);

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
            const exe_res = try c.execute(&prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Text Protocol
        const res = try c.queryRows("SELECT * FROM test.float_types_example");
        const rows: ResultSet(TextResultRow) = try res.expect(.rows);
        const table_texts = try rows.tableTexts(allocator);
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
        try std.testing.expectEqualDeep(expected, table_texts.table);
    }

    { // Select (Binary Protocol)
        const FloatTypesExample = struct {
            float_col: f32,
            double_col: f64,
        };

        const prep_res = try c.prepare(allocator, "SELECT * FROM test.float_types_example LIMIT 3");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.stmt);
        const res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const row_iter = rows.iter();

        const expected: []const FloatTypesExample = &.{
            .{ .float_col = 0, .double_col = 0 },
            .{ .float_col = -1.23, .double_col = -1.23 },
            .{ .float_col = 1.23, .double_col = 1.23 },
        };

        const structs = try row_iter.tableStructs(FloatTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.struct_list.items);
    }
}

test "binary data types - string" {
    var c = try Conn.init(std.testing.allocator, &test_config);
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
        const prep_stmt = try prep_res.expect(.stmt);

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
            const exe_res = try c.execute(&prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Text Protocol
        const res = try c.queryRows("SELECT * FROM test.string_types_example");
        const rows: ResultSet(TextResultRow) = try res.expect(.rows);

        const table_texts = try rows.tableTexts(allocator);
        defer table_texts.deinit(allocator);

        const expected: []const []const ?[]const u8 = &.{
            &.{ "hello", "world", "a", "b" },
            &.{ null, "foo", null, "c" },
            &.{ null, "", null, "a" },
            &.{ "baz", "bar", null, "c" },
        };
        try std.testing.expectEqualDeep(expected, table_texts.table);
    }

    { // Select (Binary Protocol)
        const StringTypesExample = struct {
            varchar_col: ?[]const u8,
            not_null_varchar_col: []const u8,
            enum_col: ?MyEnum,
            not_null_enum_col: MyEnum,
        };

        const prep_res = try c.prepare(allocator,
            \\SELECT * FROM test.string_types_example
        );
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.stmt);
        const res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const rows_iter = rows.iter();

        const expected: []const StringTypesExample = &.{
            .{
                .varchar_col = "hello",
                .not_null_varchar_col = "world",
                .enum_col = .a,
                .not_null_enum_col = .b,
            },
            .{
                .varchar_col = null,
                .not_null_varchar_col = "foo",
                .enum_col = null,
                .not_null_enum_col = .c,
            },
            .{
                .varchar_col = null,
                .not_null_varchar_col = "",
                .enum_col = null,
                .not_null_enum_col = .a,
            },
            .{
                .varchar_col = "baz",
                .not_null_varchar_col = "bar",
                .enum_col = null,
                .not_null_enum_col = .c,
            },
        };

        const structs = try rows_iter.tableStructs(StringTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.struct_list.items);
    }
}

test "binary data types - temporal" {
    var c = try Conn.init(std.testing.allocator, &test_config);
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
        const prep_stmt = try prep_res.expect(.stmt);

        const my_time: DateTime = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58, .microsecond = 123456 };
        const datetime_no_ms: DateTime = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 };
        const only_day: DateTime = .{ .year = 2023, .month = 11, .day = 30 };
        const my_duration: Duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59, .microseconds = 123432 }; // should be 123456 but mariadb does not round, using this example just to pass the test
        const duration_no_ms: Duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59 };
        const duration_zero: Duration = .{};

        const params = .{
            .{ my_time, my_time, my_time, my_duration, my_duration, my_duration },
            .{ datetime_no_ms, datetime_no_ms, datetime_no_ms, duration_no_ms, duration_no_ms, duration_no_ms },
            .{ only_day, only_day, only_day, duration_zero, duration_zero, duration_zero },
        };

        inline for (params) |param| {
            const exe_res = try c.execute(&prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Text Protocol
        const res = try c.queryRows("SELECT * FROM test.temporal_types_example");
        const rows: ResultSet(TextResultRow) = try res.expect(.rows);

        const table_texts = try rows.tableTexts(allocator);
        defer table_texts.deinit(allocator);

        const expected: []const []const ?[]const u8 = &.{
            &.{ "2023-11-30 06:50:58.123456", "2023-11-30 06:50:58.12", "2023-11-30 06:50:58", "47:59:59.123432", "47:59:59.1234", "47:59:59" },
            &.{ "2023-11-30 06:50:58.000000", "2023-11-30 06:50:58.00", "2023-11-30 06:50:58", "47:59:59.000000", "47:59:59.0000", "47:59:59" },
            &.{ "2023-11-30 00:00:00.000000", "2023-11-30 00:00:00.00", "2023-11-30 00:00:00", "00:00:00.000000", "00:00:00.0000", "00:00:00" },
        };

        try std.testing.expectEqualDeep(expected, table_texts.table);
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
        const prep_stmt = try prep_res.expect(.stmt);
        const res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const rows_iter = rows.iter();

        const expected: []const TemporalTypesExample = &.{
            .{
                .event_time = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58, .microsecond = 123456 },
                .event_time2 = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58, .microsecond = 120000 },
                .event_time3 = .{ .year = 2023, .month = 11, .day = 30, .hour = 6, .minute = 50, .second = 58 },
                .duration = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59, .microseconds = 123432 },
                .duration2 = .{ .days = 1, .hours = 23, .minutes = 59, .seconds = 59, .microseconds = 123400 },
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

        const structs = try rows_iter.tableStructs(TemporalTypesExample, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.struct_list.items);
    }
}

test "select concat with params" {
    var c = try Conn.init(std.testing.allocator, &test_config);
    defer c.deinit();

    { // Select (Binary Protocol)
        const prep_res = try c.prepare(allocator, "SELECT CONCAT(?, ?) AS col1");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.stmt);
        const res = try c.executeRows(&prep_stmt, .{ runtimeValue("hello"), runtimeValue("world") });
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const rows_iter = rows.iter();

        const Result = struct { col1: []const u8 };
        const expected: []const Result = &.{.{ .col1 = "helloworld" }};
        const structs = try rows_iter.tableStructs(Result, allocator);
        defer structs.deinit(allocator);
        try std.testing.expectEqualDeep(expected, structs.struct_list.items);
    }
}

fn runtimeValue(a: anytype) @TypeOf(a) {
    return a;
}
