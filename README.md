# myzql
- mysql client in zig

## Status
- very early dev

## Unit Tests
- `zig test src/myzql.zig`

## Integration Tests
- start up mysql in docker: `docker run --name some-mysql --env MYSQL_ROOT_PASSWORD=password -p 3306:3306 -d mysql --general-log=1 --log-output=FILE --general-log-file=/var/lib/mysql/mysql-general.log`
- mysql logging: `docker exec -it some-mysql tail -f /var/lib/mysql/mysql-general.log`
- run all the test: In root directory of project: `zig test integration_tests/main.zig --main-mod-path .`

## Tips
- test filter flag: `--test-filter <test name ish>`
