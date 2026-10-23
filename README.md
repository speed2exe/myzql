# MyZql
- MySQL and MariaDB driver in native zig

## Status
- Beta

## Version Compatibility
| MyZQL       | Zig                       |
|-------------|---------------------------|
| 0.0.9.1     | 0.12.0                    |
| 0.13.2      | 0.13.0                    |
| 0.14.0      | 0.14.0                    |
| 0.15.1      | 0.15.1                    |
| 0.16.1      | 0.16.0                    |
| 0.17.0      | 0.17.0                    |
| main        | 0.17.0                    |

## Features
- Native Zig code, no external dependencies
- TCP and Unix socket connections
- TLS for TCP connections (server certificate verification, custom CA)
- Prepared Statement
- Structs from query result
- Data insertion
- MySQL DateTime and Time support
- Thread-safe connection pool
- Custom log handler per config, every message bound to the config that emitted it

## Requirements
- MySQL/MariaDB 5.7.5 and up
- For TLS connections only: a Zig standard library whose TLS client handles the
  `certificate_request` message. MySQL and MariaDB always ask for a client
  certificate (with an empty list of acceptable CA names), which the standard
  library of Zig 0.17.0 and the current master answer with
  `error.TlsUnexpectedMessage`. Until a fix is released upstream, apply
  [`contrib/zig-std-tls-client-certificate-request.patch`](contrib/zig-std-tls-client-certificate-request.patch)
  to the source tree of your Zig installation and rebuild:
```bash
patch -p1 -d /path/to/zig --input path/to/myzql/contrib/zig-std-tls-client-certificate-request.patch
```
- Connections without TLS, and every other feature, work with an unpatched Zig.

## Add as dependency to your Zig project
### Fetch dependency
```bash
zig fetch --save git+https://github.com/speed2exe/myzql#0.16.1
```
or
- `build.zig.zon`
```zon
    // ...
    .dependencies = .{
      .myzql = .{
        // choose a tag according to "Version Compatibility" table
        .url = "https://github.com/speed2exe/myzql/archive/refs/tags/0.16.1.tar.gz",
        .hash = "1220582ea45580eec6b16aa93d2a9404467db8bc1d911806d367513aa40f3817f84c",
      }
    },
    // ...
```

### Import in your project
- `build.zig`
```zig
    //...
    const myzql_dep = b.dependency("myzql", .{});
    const myzql = myzql_dep.module("myzql");
    exe.root_module.addImport("myzql", myzql);
    //...
```

## Usage
- Project integration example: [Usage](https://github.com/speed2exe/myzql-example)

### Connection
```zig
const std = @import("std");
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;

    // TCP connection (default)
    var client = try Conn.init(
        allocator,
        io,
        &.{
            .username = "some-user",   // default: "root"
            .password = "password123", // default: ""
            .database = "customers",   // default: ""

            // Default: 127.0.0.1:3306
            .address = .{ .ip = std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") catch unreachable },
        },
    );
    defer client.deinit(allocator, io);

    try client.ping(io);
}
```

### Unix Socket Connection
```zig
pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;

    var client = try Conn.init(
        allocator,
        io,
        &.{
            .password = "password123",
            .address = .{ .unix = try std.Io.net.UnixAddress.init("/var/run/mysqld/mysqld.sock") },
        },
    );
    defer client.deinit(allocator, io);

    try client.ping(io);
}
```

### TLS Connection
- TLS encrypts TCP connections. Enable it with `ssl` on the config, or with the
`ssl=true` (`tls=true`) URL parameter, see [Connection from URL](#connection-from-url).
- The standard library of Zig 0.17.0 and of the current master cannot answer
the `certificate_request` message that MySQL and MariaDB send during the TLS
handshake, so TLS needs the patch of [Requirements](#requirements).
```zig
pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;

    var client = try Conn.init(
        allocator,
        io,
        &.{
            .username = "some-user",
            .password = "password123",
            .database = "customers",
            .address = .{ .host = .{ .name = try std.Io.net.HostName.init("db.example.com"), .port = 3306 } },

            .ssl = true,                          // default: false
            .ssl_verify = true,                   // default: true
            .ssl_ca = "/etc/ssl/certs/db-ca.pem", // default: null (CA certificates of the system)
        },
    );
    defer client.deinit(allocator, io);

    try client.ping(io);
}
```
- The same connection as a URL:
```zig
var url_config = try Config.fromUrl(allocator, "mysql://some-user:password123@db.example.com:3306/customers?ssl=true&sslCa=%2Fetc%2Fssl%2Fcerts%2Fdb-ca.pem");
```
- A connection is either encrypted from the start or not encrypted at all:
`ssl=true` never falls back to cleartext, a server without TLS support fails the
connection with `error.ServerDoesNotSupportTls`.
- With `ssl_verify` enabled (the default) the certificate must be signed by a
trusted CA and be issued for the host name or IP address of the connection
(the same name is sent as SNI). `ssl_ca` replaces the CA certificates of the
system with the certificates of a PEM file, which is what self-signed servers
need.
- `ssl_verify=false` still encrypts the traffic, but the server is not
authenticated, which makes the connection vulnerable to man-in-the-middle
attacks. It is meant for servers whose certificate cannot be fixed, not for
production.
- Unix domain sockets are already a local channel, so `ssl` is ignored for them
(a warning is logged) and the connection stays unencrypted.
- Accounts with `REQUIRE SSL` work, and authentication works with every
supported auth plugin: over a secure channel `caching_sha2_password` and
`sha256_password` send the password instead of requesting the RSA public key of
the server, and `mysql_native_password` works unchanged.
- Closing a connection sends the TLS `close_notify` alert before the socket is
closed.
- Connections of a pool are established and reused like plain ones; the pool
copies `ssl_ca` into memory owned by the pool, so it does not need to outlive
`Pool.init`.

### Connection from URL
- `Config.fromUrl` parses a MySQL connection URL and returns a `UrlConfig`.
- `UrlConfig` owns the decoded strings that the `Config` refers to, so it must be kept alive for the whole lifetime of the connection.
- `Pool.init` copies the config into pool-owned memory, so a pool created from a `UrlConfig` no longer depends on it.
```zig
const myzql = @import("myzql");
const Config = myzql.config.Config;
const Conn = myzql.conn.Conn;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;

    // mysql://[user[:password]@][host[:port]][/database][?parameter=value&...]
    var url_config = try Config.fromUrl(allocator, "mysql://some-user:password123@localhost:3306/customers?charset=utf8mb4");
    defer url_config.deinit(allocator);

    var client = try Conn.init(allocator, io, &url_config.value);
    defer client.deinit(allocator, io);

    try client.ping(io);
}
```
- `mysql://` and `mariadb://` are accepted.
- Every component may be percent-encoded, e.g. `mysql://us%40r:p%40ss@localhost/db`.
- Host names such as `localhost` are resolved when the connection is established,
while IP addresses (including bracketed IPv6 literals like `[::1]`) are used directly.
- Leave the host empty and add a `socket` parameter to connect over a unix domain socket:
```zig
var url_config = try Config.fromUrl(allocator, "mysql://root:password123@/customers?socket=/var/run/mysqld/mysqld.sock");
```
- Supported parameters (keys are case-insensitive):

| Parameter | Config field | Value |
|-----------|--------------|-------|
| `socket`, `unix_socket` | `address` | unix domain socket path |
| `charset` | `collation` | character set (e.g. `utf8mb4`) or collation (e.g. `utf8mb4_bin`) name |
| `clientFoundRows`, `client_found_rows` | `client_found_rows` | `true`, `false`, `1` or `0` |
| `multiStatements`, `multi_statements` | `multi_statements` | `true`, `false`, `1` or `0` |
| `ssl`, `tls` | `ssl` | `true`, `false`, `1` or `0` |
| `sslVerify`, `ssl_verify` | `ssl_verify` | `true`, `false`, `1` or `0` |
| `sslCa`, `ssl_ca` | `ssl_ca` | path to a PEM file with CA certificates |

- A parameter with an empty value keeps the default, so `?charset=` placeholders can be left in URL templates.
- Unknown parameters and invalid values are rejected (`error.UnknownUrlParameter`,
`error.InvalidUrlParameterValue`, `error.UnknownCharset`) instead of being silently ignored.
- TLS is enabled with `ssl=true` (or `tls=true`), e.g.
`mysql://user:password123@db.example.com/customers?ssl=true`. Verification,
`sslCa` and the other parameters are described in
[TLS Connection](#tls-connection).

## Querying
```zig

const OkPacket = myzql.protocol.generic_response.OkPacket;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;
    // ...
    // You can do a text query (text protocol) by using `query` method on `Conn`
    const result = try client.query(io, "CREATE DATABASE testdb");

    // Query results can have a few variant:
    // - ok:   OkPacket     => query is ok
    // - err:  ErrorPacket  => error occurred
    // In this example, result will either be `ok` or `err` (or `rows` if the query returns a result set).
    // We are using the convenient method `expect` for simplified error handling.
    // If the result variant does not match the kind of result you have specified,
    // a message will be printed and you will get an error instead.
    const ok: OkPacket = try result.expect(.ok);

    // Alternatively, you can also handle results manually for more control.
    // Here, we do a switch statement to handle all possible variant or results.
    switch (result.value) {
        .ok => |ok| {},

        // `asError` is also another convenient method to print message and return as zig error.
        // You may also choose to inspect individual fields for more control.
        .err => |err| return err.asError(),
    }
}
```

## Querying returning rows (Text Results)
- If you want to have query results to be represented by custom created structs,
this is not the section, scroll down to "Executing prepared statements returning results" instead.
- Text protocol rows are obtained by calling `query` and expecting the `.rows` variant.
```zig
const myzql = @import("myzql");
const ResultSet = myzql.result.ResultSet;
const TextResultRow = myzql.result.TextResultRow;
const TextElems = myzql.result.TextElems;
const TextElemIter = myzql.result.TextElemIter;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;
    const result = try client.query(io, "SELECT * FROM customers.purchases");

    // This is a query that returns rows, you have to collect the result.
    // you can use `expect(.rows)` to try interpret query result as ResultSet(TextResultRow)
    const rows: ResultSet(TextResultRow) = try result.expect(.rows);

    // Alternatively, if you only need the first row, you can use `rows.first(io)`.
    // It returns `?T` (`null` if there are no rows) and consumes the row.

    // Allocation-free iterator over rows.
    // Note: all rows must be consumed (iterated to `null`) before issuing another query.
    const rows_iter = rows.iter();
    while (try rows_iter.next(io)) |row| { // TextResultRow
        // Option 1: Iterate through every element in the row
        var elems_iter: TextElemIter = row.iter();
        while (elems_iter.next()) |elem| { // ?[]const u8
            std.debug.print("{?s} ", .{elem});
        }

        // Option 2: Collect all elements in the row into a slice
        const text_elems: TextElems = try row.textElems(allocator);
        defer text_elems.deinit(allocator); // elems are valid until deinit is called
        const elems: []const ?[]const u8 = text_elems.elems;
        std.debug.print("elems: {any}\n", .{elems});
    }
}
```

```zig
    // You can also use `tableTexts` to collect all rows at once.
    // Under the hood, it does network calls and allocations, until EOF or error.
    // Results are valid until `deinit` is called on TableTexts.
    const result = try client.query(io, "SELECT * FROM customers.purchases");
    const rows: ResultSet(TextResultRow) = try result.expect(.rows);
    const table = try rows.tableTexts(allocator, io);
    defer table.deinit(allocator); // table is valid until deinit is called
    std.debug.print("table: {any}\n", .{table.table});
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

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;
    // In order to do a insertion, you would first need to do a prepared statement.
    // Allocation is required as we need to store metadata of parameters and return type
    const prep_res = try client.prepare(allocator, io, "INSERT INTO test.person (name, age) VALUES (?, ?)");
    defer prep_res.deinit(allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    // Data to be inserted
    const params = .{
        .{ "John", 42 },
        .{ "Sam", 24 },
    };
    inline for (params) |param| {
        const exe_res = try client.execute(io, &prep_stmt, param);
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
const QueryResultRows = myzql.result.QueryResultRows;
const BinaryResultRow = myzql.result.BinaryResultRow;
const ResultSet = myzql.result.ResultSet;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;
    const prep_res = try client.prepare(allocator, io, "SELECT name, age FROM test.person");
    defer prep_res.deinit(allocator);
    const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

    // This is the struct that represents the columns of a single row.
    const Person = struct {
        name: []const u8,
        age: u8,
    };

    { // Iterating over rows, scanning into struct or creating struct
        const query_res = try client.execute(io, &prep_stmt, .{}); // no parameters because there's no ? in the query
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
        const rows_iter = rows.iter();
        while (try rows_iter.next(io)) |row| {
            { // Option 1: scanning into preallocated person
                var person: Person = undefined;
                try row.scan(&person);
                std.debug.print("{s} is {d} years old\n", .{ person.name, person.age });
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
                std.debug.print("{s} is {d} years old\n", .{ person_ptr.name, person_ptr.age });
            }
        }
    }

    { // collect all rows into a table ([]const Person)
        const query_res = try client.execute(io, &prep_stmt, .{}); // no parameters because there's no ? in the query
        const rows: ResultSet(BinaryResultRow) = try query_res.expect(.rows);
        const rows_iter = rows.iter();
        const person_structs = try rows_iter.tableStructs(Person, allocator, io);
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

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;
    { // Insert
        const prep_res = try client.prepare(allocator, io, "INSERT INTO test.temporal_types_example VALUES (?, ?)");
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
            const exe_res = try client.execute(io, &prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Select
        const DateTimeDuration = struct {
            event_time: DateTime,
            duration: Duration,
        };
        const prep_res = try client.prepare(allocator, io, "SELECT * FROM test.temporal_types_example");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const res = try client.execute(io, &prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const rows_iter = rows.iter();

        const structs = try rows_iter.tableStructs(DateTimeDuration, allocator, io);
        defer structs.deinit(allocator);
        std.debug.print("structs: {any}\n", .{structs.struct_list.items}); // structs.struct_list.items: []const DateTimeDuration
        // Do something with structs
    }
}
```

### Arrays Support
- Assume that you have the SQL table:
```sql
CREATE TABLE test.array_types_example (
    name VARCHAR(16) NOT NULL,
    mac_addr BINARY(6)
)
```

```zig
pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;
    { // Insert
        const prep_res = try client.prepare(allocator, io, "INSERT INTO test.array_types_example VALUES (?, ?)");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);

        const params = .{
            .{ "John", &[_]u8 { 0xFE } ** 6 },
            .{ "Alice", null }
        };
        inline for (params) |param| {
            const exe_res = try client.execute(io, &prep_stmt, param);
            _ = try exe_res.expect(.ok);
        }
    }

    { // Select
        const Client = struct {
            name: [16:1]u8,
            mac_addr: ?[6]u8,
        };
        const prep_res = try client.prepare(allocator, io, "SELECT * FROM test.array_types_example");
        defer prep_res.deinit(allocator);
        const prep_stmt: PreparedStatement = try prep_res.expect(.stmt);
        const res = try client.execute(io, &prep_stmt, .{});
        const rows: ResultSet(BinaryResultRow) = try res.expect(.rows);
        const rows_iter = rows.iter();

        const structs = try rows_iter.tableStructs(Client, allocator, io);
        defer structs.deinit(allocator);
        std.debug.print("structs: {any}\n", .{structs.struct_list.items}); // structs.struct_list.items: []const Client
        // Do something with structs
    }
}
```
- Arrays will be initialized by their sentinel value. In this example, the value of the `name` field corresponding to `John`'s row will be `[16:1]u8 { 'J', 'o', 'h', 'n', 1, 1, 1, ... }`
- If the array doesn't have a sentinel value, it will be zero-initialized.
- Insufficiently sized arrays will silently truncate excess data

### Connection Pool
- `myzql.pool.Pool` is a thread-safe connection pool.
- Connections are created lazily up to `max_size` (default: 10).
- `acquire` returns `error.PoolExhausted` when all connections are in use.
- Idle connections are health-checked (pinged) before being handed out.
```zig
const myzql = @import("myzql");
const Config = myzql.config.Config;
const Pool = myzql.pool.Pool;

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;

    const config: Config = .{ .database = "test" };
    var pool = try Pool.init(allocator, &config, .{ .max_size = 10 });
    defer pool.deinit(io);

    const managed_conn = try pool.acquireManaged(io);
    defer managed_conn.deinit(io);

    const result = try managed_conn.query(io, "SELECT 1");
    _ = try result.expect(.rows);
}
```

## Logging
- The logger is a field of `Config`, so logging is configured per config rather
  than per connection: every message the library emits on behalf of a connection
  is handed to the logger of the config that connection was created with,
  together with that config.
- If you do not set a logger, `myzql.logger.default_logger` is used, which writes
  every message with `std.log`, so nothing changes if you do not opt in.
- Set `logger` to `null` (`myzql.logger.silent`) to turn logging off: nothing is
  emitted for connections created from that config, and messages are not even
  formatted.
- Set `logger` to route the messages of a config somewhere else. The handler
  receives the config that emitted the message, so messages of configs sharing
  one sink can still be told apart.
```zig
const std = @import("std");
const myzql = @import("myzql");
const Conn = myzql.conn.Conn;
const Config = myzql.config.Config;

const LogSink = struct {
    messages: std.atomic.Value(usize) = .init(0),

    fn logFn(
        context: ?*anyopaque,
        config: ?*const Config,
        level: std.log.Level,
        message: []const u8,
    ) void {
        const sink: *LogSink = @ptrCast(@alignCast(context.?));
        _ = sink.messages.fetchAdd(1, .monotonic);

        // `config` is the config the message was emitted for. Its fields (e.g.
        // the database) tell the clients apart, so one sink serves many of them.
        // It is null only for a message that has no config behind it, e.g. one
        // emitted by a value that was built by hand.
        const database = if (config) |c| c.database else "";

        switch (level) {
            .err => std.log.scoped(.myzql).err("[{s}] {s}", .{ database, message }),
            .warn => std.log.scoped(.myzql).warn("[{s}] {s}", .{ database, message }),
            .info => std.log.scoped(.myzql).info("[{s}] {s}", .{ database, message }),
            .debug => std.log.scoped(.myzql).debug("[{s}] {s}", .{ database, message }),
        }
    }
};

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const allocator = std.heap.page_allocator;

    var sink: LogSink = .{};

    var config: Config = .{
        .database = "customers",
        .password = "password123",
        .logger = .{ .context = &sink, .logFn = LogSink.logFn },
    };

    // messages of this connection go to `sink`
    var client = try Conn.init(allocator, io, &config);
    defer client.deinit(allocator, io);

    // a copy of the config with logging turned off: connections created from it
    // stay quiet
    var quiet_config = config;
    quiet_config.logger = myzql.logger.silent;
    var quiet_client = try Conn.init(allocator, io, &quiet_config);
    defer quiet_client.deinit(allocator, io);
}
```
- The handler type is `myzql.logger.Logger`:
  - `logFn: fn (context: ?*anyopaque, config: ?*const Config, level: std.log.Level, message: []const u8) void`.
  - `context` is passed back unchanged, which is how one sink serves many configs.
  - `config` is the config the message belongs to, so its fields identify the
    client that emitted it. It is `null` only when a message has no config behind
    it, e.g. one emitted by a value that was built by hand.
  - `logFn` defaults to `myzql.logger.defaultLogFn`, so `logger = .{}` (a
    `Logger` with only a `context`, or with no fields at all) still writes with
    `std.log`. Leaving the field alone already gives you
    `myzql.logger.default_logger`, i.e. `Config{}.logger.?.logFn == myzql.logger.defaultLogFn`.
- `null` is not "unset", it is the way to disable logging; leaving the field out
  is "unset" and keeps the default logger.
- `message` is already formatted and has no trailing newline.
- Messages are formatted in a fixed stack buffer: anything longer than
  `myzql.logger.max_message_len` (1024 bytes) is truncated, never dropped.
- The handler is called synchronously on the thread that emitted the message,
  so it must be thread-safe when connections are shared (see
  [Connection Pool](#connection-pool)).
- The config must outlive the connections created from it, since a connection
  logs through the config it was created with.
- Connections created by a `Pool` log through the pool's own copy of the config,
  so `config` is the copy owned by the pool, not the one passed to `Pool.init`.
- Only the messages of this library are routed, `std.log` calls of your own code
  are untouched; the default handler (`std.log`) keeps the previous behavior.

## Unit Tests
- `zig build unit_test`

## Integration Tests
- Start up mysql/mariadb in docker:
```bash
# MySQL (TCP)
docker run --name some-mysql --env MYSQL_ROOT_PASSWORD=password -p 3306:3306 -d mysql
```
```bash
# MySQL (Unix socket)
mkdir -p /tmp/mysql
docker run --name some-mysql-unix --env MYSQL_ROOT_PASSWORD=password -v /tmp/mysql:/var/run/mysqld -d mysql
```
```bash
# MariaDB
docker run --name some-mariadb --env MARIADB_ROOT_PASSWORD=password -p 3306:3306 -d mariadb
```
- Run all the tests from the root directory of the project:
```bash
zig build integration_test --summary all
```
- Run with a filter:
```bash
zig build -Dtest-filter="..." integration_test
```
- Run unix socket tests:
```bash
zig build integration_test -Dunix-socket-path=/tmp/mysql/mysqld.sock -Dtest-filter="unix socket" --summary all
```
- Skip the heavy stress test (16M rows, useful for CI):
```bash
zig build integration_test -Dskip-stress=true --summary all
```
- Run the TLS tests. The script needs `docker` and `openssl`: it generates a CA
  and the server certificates into a temporary directory, builds the image of
  `integration_tests/tls/Dockerfile` and starts three servers (MySQL with TLS,
  MySQL with a certificate for another host name and MariaDB without TLS):
```bash
./integration_tests/tls/docker-test.sh --summary all
```
The ports of the servers can be changed with `MYZQL_TLS_PORT` (default `3306`),
`MYZQL_WRONG_HOST_PORT` (default `3308`) and `MYZQL_NOTLS_PORT` (default
`3307`). With an unpatched Zig the TLS connections fail with
`error.TlsUnexpectedMessage`, see [Requirements](#requirements).
- To run the TLS tests against servers that are already running:
```bash
zig build integration_test -Dskip-stress=true \
    -Dtls-ca-path=/path/to/ca.pem \
    -Dtls-wrong-host-port=3308 \
    -Dnotls-port=3307 \
    -Dtest-filter="tls - " --summary all
```
`-Dtls-ca-path` is the CA that signed the certificate of the server on `3306`,
`-Dtls-wrong-host-port` is a TLS server whose certificate is not valid for
`127.0.0.1` and `-Dnotls-port` is a server without TLS support. Without
`-Dtls-ca-path` the TLS tests are skipped, so the servers are only needed for
the two commands above. The test of the unix socket behaviour additionally
needs `-Dunix-socket-path`.

## Philosophy
### Correctness
Focused on correct representation of server client protocol.
### Low-level and High-level APIs
Low-level apis should contain all functionality you need.
High-level apis are built on top of low-level ones for convenience and developer ergonomics.

### Binary Column Types support
- MySQL Column Types to Zig Values
```
- Null -> ?T
- Int -> u64, u32, u16, u8, i64, i32, i16, i8
- Float -> f32, f64
- String -> []u8, []const u8, enum
- Date/Datetime/Timestamp -> DateTime
- Time -> Duration
- String/Bytes -> [N]u8, [N:0]u8 (sentinel-filled, zero-filled if no sentinel, or truncated if too small)
```
