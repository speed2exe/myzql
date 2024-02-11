# MyZql
- MySQL and MariaDB driver in native zig

## Status
- Beta

## Features
- Native Zig code, no external dependencies
- TCP protocol
- MySQL DateTime and Time support
- Query Results to struct

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
	    .url = "https://github.com/speed2exe/myzql/archive/refs/tags/0.0.4.tar.gz", // replace tag version as needed
        .hash = "122021c467d780838f6225f90d5a5f42019afdc54d83ef0bceb5c8fd4e5e4df4a965",
	}
    // ...
```

## Usage
- Project integration example: [Usage](https://github.com/speed2exe/myzql-example)

### Connection
```zig
const myzql = @import("myzql");
const Client = myzql.client.Client;

pub fn main() !void {
    // Setting up client
    var client = Client.init(.{
        .username = "some-user",   // default: "root"
        .password = "password123", // default: ""
        .database = "customers",   // default: ""

        // Current default value.
        // Use std.net.getAddressList if you need to look up ip based on hostname
        .address =  std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3306),

        // ...
    });
    // Connection and Authentication
    try client.ping(allocator);
}
```
Note:
- Allocation and connection are lazy by default, and will be required when required (e.g. query or ping).
- Allocator is stored in `Client`, and will NOT do implicit allocation for user. Every function or method
that requires allocation explicitly require an allocator.
This is done so that allocation strategy can be optimized.
E.g. Supposed you can guarantee that the data returned from query result have reasonable upper bound(eg. `SELECT COUNT(*) FROM my_table`),
you can use a fixed buffer allocation strategy to avoid heap allocation.

## Querying
```zig

const OkPacket = protocol.generic_response.OkPacket;

pub fn main() !void {
    // ...
    // You can do a text query (text protocol) by using `query` method on `Client`
    // Observe that an allocator is required. This is because the driver cannot determine
    // the amount of allocation that is required for this call. If you might be able to
    // reasonably predict the upper bound of this operation, you can provide a more optimized allocator.
    // You may also do insertion query here, but it will not be optimal and will be more
    // vulnerable to SQL injection attacks.
    const result = try c.query(allocator, "CREATE DATABASE testdb");
    defer result.deinit(allocator); // rememeber to deinit the result

    // Query results can have a few variant:
    // - ok:   OkPacket     => error occurred
    // - err:  ErrorPacket  => query is fine
    // - rows: ResultSet(TextResultData) => rows returned from server
    // In this example, the query is not returning any result, so it will either be `ok` or `err`.
    // We are using the convenient method `expect` for simplified error handling.
    // You can also do `expect(.err)` or `expect(.rows)`, if the result variant does not match
    // what you have specified, a message will be printed and you will get an error instead.
    const ok: OkPacket = try result.expect(.ok);

    // Alternatively, you can also handle results manually if you want more control.
    // Here, we do a switch statement to handle all possible variant or results.
    switch (result.value) {
        .ok => |ok| {
            std.debug.print("ok packet from server = {any}", .{ok});
        },
        // `asError` is also another convenient method to print message and return error.
        // You may also choose to inspect individual elements for more control.
        .err => |err| return err.asError(),

        // Result rows will be covered below
        .rows => |rows| {
            _ = rows;
            @panic("should not expect rows");
        },
    }
}
```

## Querying returning rows (Text Results)
- If you want to have query results to be represented as struct, this is not the section, scroll down to "Executing prepared statements returning results" instead
```zig
const myzql = @import("myzql");
const QueryResult = myzql.result.QueryResult;
const ResultSet = myzql.result.ResultSet;
const ResultRow = myzql.result.ResultRow;
const TextResultData = myzql.result.TextResultData;
const ResultSetIter = myzql.result.ResultSetIter;
const TableTexts = myzql.result.TableTexts;

pub fn main() !void {
    const result = try c.query(allocator, "SELECT * FROM customers.purchases");
    defer result.deinit(allocator);

    // If you have a query that returns rows, you have to collect the result.
    // you can use `expect(.rows)` to get rows.
    const rows: ResultSet(TextResultData) = try query_res.expect(.rows);
    // Each time you call a `readRow` on row, you will get a `ResultRow(TextResultData)` type.
    // This is likely a spot where allocation can be optimized, since a single row allocation
    // can be easily estimated.
    // This may or may not invoke a network call depending on buffer of the network reader.
    //
    // There are few variant of ResultRow(TextResultData):
    // - err:  ErrorPacket    => An error occurred.
    // - ok:   OkPacket       => Indicates that there are not more rows to read
    //                           and so you must not call `readRow` again on this result.
    // - data: TextResultData => Data representing the row.
    const row: ResultRow(TextResultData) = try rows.readRow(allocator);
    defer row.deinit(allocator);
    // using `expect` to assert that we want are expecting data:
    const data: TextResultData = try row.expect(.data);

    // There are a few ways to get the data ino the format that you want
    // If you already have a placeholder, you can try scan it:
    var dest = [_]?[]const u8{ undefined, undefined };
    try data.scan(&dest);
    // If you want to allocate on the fly: you can do:
    const dest: []?[]const u8 = try data.scanAlloc(allocator);

    // Iterating over rows
    // This is more convenient and probably suitable for most use cases.
    const it: ResultSetIter(TextResultData) = rows.iter();
    while (try it.next(allocator)) |row| {
        defer row.deinit(allocator);
        // do something with row
    }
    // Collecting all data from iterator (another convenient method)
    const table: TableTexts = try it.collectTexts(allocator);
    defer table.deinit(allocator);
    const all_rows: []const []const ?[]const u8 = table.rows;
    all_rows.debugPrint(); // prints out the content to terminal

    // IMPORTANT:
    // Underlying data remains in the ResultRow(TextResultData),
    // which is in the network reader buffer.
    // your data will be valid until it goes out of scope, do a copy if needed.
    // If you find a common tedious use case, feel free to file a Feature Request.
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
const PrepareResult = myzql.result.PrepareResult;
const QueryResult = myzql.result.QueryResult;
const PreparedStatement = myzql.result.PreparedStatement;
const BinaryResultData = myzql.result.BinaryResultData;

pub fn main() void {
    // In order to do a insertion, you would first need to do a prepared statement.
    const prep_res: PrepareResult = try c.prepare(allocator, "INSERT INTO test.person (name, age) VALUES (?, ?)");
    defer prep_res.deinit(allocator);

    // PrepareResult has 2 variant:
    // ok:  PreparedStatement => contains id and metadata for query execution
    // err: ErrorPacket       => something gone wrong
    // In this example, we use `expect(.ok)` to get PreparedStatement
    const prep_stmt: PreparedStatement = try prep_res.expect(.ok);
    // Preparing the params to be inserted
    const params = .{
        .{ "John", 42 },
        .{ "Sam", 24 },
    };
    inline for (params) |param| {
        const exe_res: QueryResult(BinaryResultData) = try c.execute(allocator, &prep_stmt, param);
        defer exe_res.deinit(allocator);
        // Just like QueryReselt(TextResultData), QueryResult(BinaryResultData) has 3 variant
        // QueryResult(BinaryResultData) has 3 variant:
        // - ok:   OkPacket     => error occurred
        // - err:  ErrorPacket  => query is fine
        // - rows: ResultSet(BinaryResultData) => rows returned from server
        // as we are not expecting any rows, we can just `expect(.ok)` to get the OkPacket
        const ok: OkPacket = try exe_res.expect(.ok);
        // If you need the id that was last_inserted, here's how to get it.
        const last_insert_id: u64 = ok.last_insert_id;
        std.debug.print("last_insert_id: {any}\n", .{last_insert_id});
    }

    // Currently only tuples are supported as an argument for insertion.
    // There are plans to include named structs in the future.
}
```

### Executing prepared statements returning results
```zig
const ResultSetIter = myzql.result.ResultSetIter;
const QueryResult = myzql.result.QueryResult;
const BinaryResultData = myzql.result.BinaryResultData;
const TableStructs = myzql.result.TableStructs;

fn main() !void {
    const prep_res = try c.prepare(allocator, "SELECT name, age FROM test.person");
    defer prep_res.deinit(allocator);
    const prep_stmt = try prep_res.expect(.ok);

    // This is the struct that represents the columns of a single row.
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    // Execute query and get an iterator from results
    const res: QueryResult(BinaryResultData) = try c.execute(allocator, &prep_stmt, .{});
    defer res.deinit(allocator);
    const rows: ResultSet(BinaryResultData) = try res.expect(.rows);
    const iter: ResultSetIter(BinaryResultData) = rows.iter();

    // Interate over the rows,
    while (try iter.next(allocator)) |row| {
        defer row.deinit(allocator);
        const data: BinaryResultData = try row.expect(.data);

        // If you preallocated `my_guy` and want to copy result into it
        var my_guy: Person = undefined;
        try data.scan(&my_guy, allocator);
        std.debug.print("my_guy: {any}\n", .{my_guy});

        // If you want to allocate on the fly
        const person = try data.scanAlloc(Person, allocator);
        defer allocator.destroy(person); // make sure you destroy the allocated after use
        std.debug.print("person: {any}\n", .{person});
    }

    // There is another convenient method that uses the interator
    // to interate through all the rows until EOF
    // and collecting them into a data structure.
    const people_structs: TableStructs(Person) = try iter.collectStructs(DateTimeDuration, allocator);
    defer people_structs.deinit(allocator);
    const people []const Person = people_structs.rows;
    //... do something with people
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

        // Do prepared statement on the server
        const prep_res = try c.prepare(allocator, "INSERT INTO test.temporal_types_example VALUES (?, ?)");
        defer prep_res.deinit(allocator);
        const prep_stmt = try prep_res.expect(.ok);

        // Data for Insertion
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
        const params = .{
            .{ my_time, my_duration },
        };
        inline for (params) |param| {
            // network call to insert data
            const exe_res = try c.execute(allocator, &prep_stmt, param);
            defer exe_res.deinit(allocator);
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
        const prep_stmt = try prep_res.expect(.ok);
        const res = try c.execute(allocator, &prep_stmt, .{});
        defer res.deinit(allocator);
        const rows_iter = (try res.expect(.rows)).iter();

        const structs = try rows_iter.collectStructs(DateTimeDuration, allocator);
        defer structs.deinit(allocator);
        std.debug.print("structs: {any}\n", .{structs.rows}); // structs.rows: []const DateTimeDuration
        // Do something with structs
        // ...
    }
}
```

## Unit Tests
- `zig test src/myzql.zig`

## Integration Tests
- Start up mysql/mariadb in docker:
  - `docker run --name some-mysql --env MYSQL_ROOT_PASSWORD=password -p 3306:3306 -d mysql`
  - `docker run --name some-mariadb --env MARIADB_ROOT_PASSWORD=password -p 3306:3306 -d mariadb`
- Run all the test: In root directory of project: `zig test --dep myzql --mod root ./integration_tests/main.zig --mod myzql ./src/myzql.zig --name test`

### Tips
- test filter flag: `--test-filter <test name ish>`

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
