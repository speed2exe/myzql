# MyZql
- MySQL and MariaDB driver in native zig

## Status
- Beta

## Features
- Native Zig code, no external dependencies
- TCP protocol
- Prepared Statement
- Structs from query result
- Data insertion
- MySQL DateTime and Time support

## Requirements
- MySQL/MariaDB 5.7.5 and up

## TODOs
- Config from URL
- Connection Pooling
- TLS support

## Add as dependency to your Zig project
- `build.zig`
```zig
    //...
    const myzql_dep = b.dependency("myzql", .{});
    const myzql = myzql_dep.module("myzql");
    exe.addModule("myzql", myzql);
    //...
```

- `build.zig.zon`
```zon
    // ...
    .dependencies = .{
        .myzql = .{
	    .url = "https://github.com/speed2exe/myzql/archive/refs/tags/0.0.5.tar.gz", // do check tags for newer versions
        .hash = "122021c467d780838f6225f90d5a5f42019afdc54d83ef0bceb5c8fd4e5e4df4a965",
	}
    // ...
```

## Usage
- Project integration example: [Usage](https://github.com/speed2exe/myzql-example)

### Connection
```zig
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;

pub fn main() !void {
    // Setting up client
    var client = try Conn.init(
        allocator,
        &.{
            .username = "some-user",   // default: "root"
            .password = "password123", // default: ""
            .database = "customers",   // default: ""

            // Current default value.
            // Use std.net.getAddressList if you need to look up ip based on hostname
            .address =  std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3306),
            // ...
        },
    );
    defer client.deinit();

    // Connection and Authentication
    try client.ping();
}
```
Note:
- Allocation and network are lazy by default and will only be invoked when needed (e.g. query or ping).
- Allocator is not stored in `Conn`, and will NOT do implicit allocation for user. Every function or method
that requires allocation will require an allocator to be passed in as parameter.
This is done so that allocation strategy can be optimized.

## Querying
```zig

const OkPacket = protocol.generic_response.OkPacket;

pub fn main() !void {
    // ...
    // You can do a text query (text protocol) by using `query` method on `Conn`
    // Allocator is required in an event that there are rows returned from the server,
    // If there are no rows returned, it is safe to not call `deinit`
    // If you are able to have an upper bound of this operation, you can provide a more optimized allocator.
    // You may also do insertion query here, but it will not be optimal and will be more
    // vulnerable to SQL injection attacks.
    const result = try c.query("CREATE DATABASE testdb");

    // Query results can have a few variant:
    // - ok:   OkPacket     => error occurred
    // - err:  ErrorPacket  => query is fine
    // - rows: ResultSet(TextResultData) => rows returned from server
    // In this example, the query is not returning any result, so it will either be `ok` or `err`.
    // We are using the convenient method `expect` for simplified error handling.
    // You can also do `expect(.err)` or `expect(.rows)`.
    // If the result variant does not match the kind of result you have specified,
    // a message will be printed and you will get an error instead.
    const ok: OkPacket = try result.expect(.ok);

    // Alternatively, you can also handle results manually for more control.
    // Here, we do a switch statement to handle all possible variant or results.
    switch (result.value) {
        .ok => |ok| {},

        // `asError` is also another convenient method to print message and return as zig error.
        // You may also choose to inspect individual elements for more control.
        .err => |err| return err.asError(),

        // query results that returns data
        .rows => |rows| {
            _ = rows;
            @panic("should not expect rows");
        },
    }
}
```

## Querying returning rows (Text Results)
- If you want to have query results to be represented by custom created structs,
this is not the section, scroll down to "Executing prepared statements returning results" instead.
```zig
const myzql = @import("myzql");
const QueryResult = myzql.result.QueryResult;
const ResultSet = myzql.result.ResultSet;
const ResultRow = myzql.result.ResultRow;
const TextResultRow = myzql.result.TextResultData;
const ResultSetIter = myzql.result.ResultSetIter;
const TableTexts = myzql.result.TableTexts;
const TextElemIter = myzql.result.TextElemIter;

pub fn main() !void {
    const result = try c.queryRows("SELECT * FROM customers.purchases");

    // This is a query that returns rows, you have to collect the result.
    // you can use `expect(.rows)` to try interpret query result as ResultSet(TextResultRow)
    const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);

    // Allocation free interators
    const rows_iter: ResultRowIter(TextResultRow) = rows.iter();
    { // Option 1: Iterate through every row and elem
        while (try rows_iter.next()) |row| { // ResultRow(TextResultRow)
            var elems_iter: TextElemIter = row.iter();
            while (elems_iter.next()) |elem| { // ?[] const u8
                std.debug.print("{?s} ", .{elem});
            }
        }
    }
    { // Option 2: Iterating over rows, collecting elements into []const ?[]const u8
        while (try rows_iter.next()) |row| {
            const text_elems: TextElems = try row.textElems(allocator);
            defer text_elems.deinit(allocator); // elems are valid until deinit is called
            const elems: []const ?[]const u8 = text_elems.elems;
            std.debug.print("elems: {any}\n", .{elems});
        }
    }

    // You can also use `collectTexts` method to collect all rows.
    // Under the hood, it does network call and allocations, until EOF or error
    // Results are valid until `deinit` is called on TableTexts.
    const rows: ResultSet(TextResultRow) = try query_res.expect(.rows);
    const table = try rows.tableTexts(allocator);
    defer table.deinit(allocator); // table is valid until deinit is called
    std.debug.print("table: {any}\n", .{table.table});
}

```

### Data Insertion
- Let's assume that you have a table of this structure:
```sql
CREATE TABLE test.person (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255),
    age INT
)
```

```zig
const myzql = @import("myzql");
const QueryResult = myzql.result.QueryResult;
const PreparedStatement = myzql.result.PreparedStatement;
const OkPacket = myzql.protocol.generic_response.OkPacket;

pub fn main() void {
    // In order to do a insertion, you would first need to do a prepared statement.
    // Allocation is required as we need to store metadata of parameters and return type
    const prep_res = try c.prepare(allocator, "INSERT INTO test.person (name, age) VALUES (?, ?)");
    defer prep_res.deinit(allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    // Data to be inserted
    const params = .{
        .{ "John", 42 },
        .{ "Sam", 24 },
    };
    inline for (params) |param| {
        const exe_res = try c.execute(&prep_stmt, param);
        const ok: OkPacket = try exe_res.expect(.ok); // expecting ok here because there's no rows returned
        const last_insert_id: u64 = ok.last_insert_id;
        std.debug.print("last_insert_id: {any}\n", .{last_insert_id});
    }

    // Currently only tuples are supported as an argument for insertion.
    // There are plans to include named structs in the future.
}
```

### Executing prepared statements returning results as structs
```zig
const ResultSetIter = myzql.result.ResultSetIter;
const QueryResult = myzql.result.QueryResult;
const BinaryResultRow = myzql.result.BinaryResultRow;
const TableStructs = myzql.result.TableStructs;
const ResultSet = myzql.result.ResultSet;

fn main() !void {
    const prep_res = try c.prepare(allocator, "SELECT name, age FROM test.person");
    defer prep_res.deinit(allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    // This is the struct that represents the columns of a single row.
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    // Execute query and get an iterator from results
    const res: QueryResult(BinaryResultRow) = try c.executeRows(&prep_stmt, .{});
    const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
    const iter: ResultSetIter(BinaryResultRow) = rows.iter();

    { // Iterating over rows, scanning into struct or creating struct
        const query_res = try c.executeRows(&prep_stmt, .{}); // no parameters because there's no ? in the query
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
        const rows_iter = rows.iter();
        while (try rows_iter.next()) |row| {
            { // Option 1: scanning into preallocated person
                var person: Person = undefined;
                try row.scan(&person);
                person.greet();
                // Important: if any field is a string, it will be valid until the next row is scanned
                // or next query. If your rows return have strings and you want to keep the data longer,
                // use the method below instead.
            }
            { // Option 2: passing in allocator to create person
                const person_ptr = try row.structCreate(Person, allocator);

                // Important: please use BinaryResultRow.structDestroy
                // to destroy the struct created by BinaryResultRow.structCreate
                // if your struct contains strings.
                // person is valid until BinaryResultRow.structDestroy is called.
                defer BinaryResultRow.structDestroy(person_ptr, allocator);
                person_ptr.greet();
            }
        }
    }

    { // collect all rows into a table ([]const Person)
        const query_res = try c.executeRows(&prep_stmt, .{}); // no parameters because there's no ? in the query
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
        const rows_iter = rows.iter();
        const person_structs = try rows_iter.tableStructs(Person, allocator);
        defer person_structs.deinit(allocator); // data is valid until deinit is called
        std.debug.print("person_structs: {any}\n", .{person_structs.struct_list.items});
    }
}
```

### Temporal Types Support (DateTime, Time)
- Example of using DateTime and Time MySQL column types.
- Let's assume you already got this table set up:
```sql
CREATE TABLE test.temporal_types_example (
    event_time DATETIME(6) NOT NULL,
    duration TIME(6) NOT NULL
)
```


```zig

const DateTime = myzql.temporal.DateTime;
const Duration = myzql.temporal.Duration;

fn main() !void {
    { // Insert
        const prep_res = try c.prepare(allocator, "INSERT INTO test.temporal_types_example VALUES (?, ?)");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

        const my_time: DateTime = .{
            .year = 2023,
            .month = 11,
            .day = 30,
            .hour = 6,
            .minute = 50,
            .second = 58,
            .microsecond = 123456,
        };
        const my_duration: Duration = .{
            .days = 1,
            .hours = 23,
            .minutes = 59,
            .seconds = 59,
            .microseconds = 123456,
        };
        const params = .{.{ my_time, my_duration }};
        inline for (params) |param| {
            const exe_res = try c.execute(&prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Select
        const DateTimeDuration = struct {
            event_time: DateTime,
            duration: Duration,
        };
        const prep_res = try c.prepare(allocator, "SELECT * FROM test.temporal_types_example");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const res = try c.executeRows(&prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const rows_iter = rows.iter();

        const structs = try rows_iter.tableStructs(DateTimeDuration, allocator);
        defer structs.deinit(allocator);
        std.debug.print("structs: {any}\n", .{structs.struct_list.items}); // structs.rows: []const DateTimeDuration
        // Do something with structs
    }
}
```

## Unit Tests
- `zig test src/myzql.zig`

## Integration Tests
- Start up mysql/mariadb in docker:
  - `docker run --name some-mysql --env MYSQL_ROOT_PASSWORD=password -p 3306:3306 -d mysql`
  - `docker run --name some-mariadb --env MARIADB_ROOT_PASSWORD=password -p 3306:3306 -d mariadb`
- Run all the test: In root directory of project: `zig test integration_test -Dtest-filer='...'`

## Philosophy
### Correctness
Focused on correct representation of server client protocol.
### Low-level and High-level APIs
Low-level apis should contain all information you need.
High-level apis are built on top of low-level ones for convenience and developer ergonomics.
### Explicit memory allocation
Requires user to provide allocator whenever there is allocation involved(querying, data fetching, etc).
This is done so that allocation strategy can be optimized.
E.g. Supposed you can guarantee that the data returned from query result have reasonable upper bound(eg. `SELECT COUNT(*) FROM my_table`),
you can use a fixed buffer allocation strategy.

### Binary Column Types support
- MySQL Colums Types to Zig Values
```
- Null -> ?T
- Int -> u64, u32, u16, u8
- Float -> f32, f64
- String -> []u8, []const u8, enum
```
