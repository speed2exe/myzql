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
        const query_res = try c.query(allocator, "SELECT 1");
        defer query_res.deinit(allocator);

        const rows = (try expectRows(query_res.value)).iter();
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
        const rows = (try expectRows(query_res.value)).iter();

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
        const rows = (try expectRows(query_res.value)).iter();
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
        const rows = try expectRows(query_res.value);

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

test "query text table" {
    var c = Client.init(test_config);
    defer c.deinit();

    {
        const query_res = try c.query(allocator, "SELECT 1,2,3 UNION ALL SELECT 4,null,6");
        defer query_res.deinit(allocator);
        const iter = (try expectRows(query_res.value)).iter();
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
        _ = try expectOk(prep_res.value);
    }
    { // prepare with params
        const prep_res = try c.prepare(allocator, "SELECT CONCAT(?, ?) as my_col");
        defer prep_res.deinit(allocator);

        switch (prep_res.value) {
            .ok => |prep_stmt| {
                try std.testing.expectEqual(prep_stmt.prep_ok.num_params, 2);
                try std.testing.expectEqual(prep_stmt.prep_ok.num_columns, 1);
            },
            else => return errorUnexpectedValue(prep_res.value),
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
        const prep_stmt = try expectOk(prep_res.value);
        const query_res = try c.execute(allocator, &prep_stmt);
        defer query_res.deinit(allocator);
        _ = try expectOk(query_res.value);
    }
    {
        const prep_res = try c.prepare(allocator, "DROP DATABASE testdb2");
        defer prep_res.deinit(allocator);
        const prep_ok = try expectOk(prep_res.value);
        const query_res = try c.execute(allocator, &prep_ok);
        defer query_res.deinit(allocator);
        _ = try expectOk(query_res.value);
    }
}

test "prepare execute - 2" {
    var c = Client.init(test_config);
    defer c.deinit();

    const prep_res_1 = try c.prepare(allocator, "CREATE DATABASE testdb3");
    defer prep_res_1.deinit(allocator);
    const prep_stmt_1 = try expectOk(prep_res_1.value);

    const prep_res_2 = try c.prepare(allocator, "DROP DATABASE testdb3");
    defer prep_res_2.deinit(allocator);
    const prep_stmt_2 = try expectOk(prep_res_2.value);

    {
        const query_res = try c.execute(allocator, &prep_stmt_1);
        defer query_res.deinit(allocator);
        _ = try expectOk(query_res.value);
    }
    {
        const query_res = try c.execute(allocator, &prep_stmt_2);
        defer query_res.deinit(allocator);
        _ = try expectOk(query_res.value);
    }
}

// test "prepare execute with result" {
//     var c = Client.init(test_config);
//     defer c.deinit();
//
//     {
//         const query =
//             \\SELECT 1,2,3,4,5
//         ;
//         const prep_res = try c.prepare(allocator, query);
//         defer prep_res.deinit(allocator);
//         const prep_ok = try expectOk(prep_res.value);
//         _ = prep_ok;
//         // const query_res = try c.execute(allocator, &prep_ok);
//         // defer query_res.deinit(allocator);
//         // const rows = (try expectRows(query_res.value)).iter();
//         // while (try rows.next(allocator)) |row| {
//         //     std.debug.print("row: {any}\n", .{row.value.raw});
//         //     defer row.deinit(allocator);
//         // }
//     }
// }

// SELECT CONCAT(?, ?) AS col1
