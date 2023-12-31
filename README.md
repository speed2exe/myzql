# MyZql
- MySQL driver written in pure zig

## Status
- Alpha

## Features
- Native Zig code
- TCP protocol
- MySQL DateTime and Time support
- comptime safety and type conversion as much as possible

### Binary Column Types support
- MySQL Colums Types to Zig Values
```
- Null -> ?T
- Int -> u64, u32, u16, u8
- Float -> f32, f64
- String -> []u8, []const u8, enum
```

## Getting started
Follow examples below:
- [Examples](https://github.com/speed2exe/myzql-example)

## Upcoming Implementation
- Connection Pooling
- Bulk Insert
- Infile Insertion
- TLS support
- struct array as param input

## Unit Tests
- `zig test src/myzql.zig`

## Integration Tests
- start up mysql in docker: `docker run --name some-mysql --env MYSQL_ROOT_PASSWORD=password -p 3306:3306 -d mysql --general-log=1 --log-output=FILE --general-log-file=/var/lib/mysql/mysql-general.log`
- mysql logging: `docker exec -it some-mysql tail -f /var/lib/mysql/mysql-general.log`
- run all the test: In root directory of project: `zig test integration_tests/main.zig --main-mod-path .`

### Tips
- test filter flag: `--test-filter <test name ish>`
