# MyZql
- MySQL/MariaDB driver written in pure zig

## Status
- Alpha

## Features
- Native Zig code
- TCP protocol
- MySQL DateTime and Time support
- comptime safety and type conversion as much as possible

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
	    .url = "https://github.com/speed2exe/myzql/archive/refs/tags/0.0.2.tar.gz", // replace tag version as needed
            .hash = "122021c467d780838f6225f90d5a5f42019afdc54d83ef0bceb5c8fd4e5e4df4a965",
	}
    // ...
```

## Examples
- [Usage](https://github.com/speed2exe/myzql-example)

## Upcoming Implementations
- config from URL
- Connection Pooling
- Bulk Insert
- Infile Insertion
- TLS support
- struct array as param input

## Unit Tests
- `zig test src/myzql.zig`

## Integration Tests
- Start up mysql/mariadb in docker:
  - `docker run --name some-mysql --env MYSQL_ROOT_PASSWORD=password -p 3306:3306 -d mysql`
  - `docker run --name some-mariadb --env MARIADB_ROOT_PASSWORD=password -p 3306:3306 -d mariadb`
- Run all the test: In root directory of project: `zig test integration_tests/main.zig --main-mod-path .`

### Tips
- test filter flag: `--test-filter <test name ish>`
