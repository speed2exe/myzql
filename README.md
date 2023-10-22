# myzql
- mysql client in zig

## Status
- Vaporware 

## Features
### Connection
[x] Connection with no password
[ ] `caching_sha2_password` authentication
[ ] TLS

### Client
[x] Ping
[x] Query Protocol
[ ] Query Results
[ ] Query Params


## Unit Tests
- `zig test src/myzql.zig`

## Integration Tests
- start up mysql in docker: `docker run --name some-mysql --env MYSQL_ALLOW_EMPTY_PASSWORD=1 -p 3306:3306 -d mysql --general-log=1 --log-output=FILE --general-log-file=/var/lib/mysql/mysql-general.log`
  - TODO:  switch to use `--env MYSQL_ROOT_PASSWORD=password` eventually after password auth or TLS is supported
- mysql logging: `docker exec -it some-mysql tail -f /var/lib/mysql/mysql-general.log`
- run all the test: In root directory of project: `zig test integration_tests/main.zig --main-mod-path .`

### Tips
- test filter flag: `--test-filter <test name ish>`
