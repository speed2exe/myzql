# myzql
- mysql client in zig

## Status
- very early dev

## Test
- spin up mysql: `docker run --name some-mysql --env MYSQL_ALLOW_EMPTY_PASSWORD=1 -p 3306:3306 -d mysql --general-log=1 --log-output=FILE --general-log-file=/var/lib/mysql/mysql-general.log`
- mysql logging: `docker exec -it some-mysql tail -f /var/lib/mysql/mysql-general.log`
- run the test `zig build test`
