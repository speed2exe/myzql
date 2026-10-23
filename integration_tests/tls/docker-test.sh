#!/usr/bin/env bash
# Run the TLS integration tests against Docker hosted MySQL and MariaDB servers.
#
#   integration_tests/tls/docker-test.sh [extra `zig build integration_test` args]
#
# Three servers are started:
# - 127.0.0.1:3306 MySQL 8.0 with TLS and a certificate for localhost/127.0.0.1
# - 127.0.0.1:3308 MySQL 8.0 with TLS and a certificate for another host name
# - 127.0.0.1:3307 MariaDB without TLS support
#
# The certificates are generated into a temporary directory with `openssl`, so no
# key material is stored in the repository. Both `docker` and `openssl` have to be
# available. The containers are removed again when the script exits.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tls_port="${MYZQL_TLS_PORT:-3306}"
wrong_host_port="${MYZQL_WRONG_HOST_PORT:-3308}"
notls_port="${MYZQL_NOTLS_PORT:-3307}"
image=myzql-mysql-tls:8.0
work_dir="$(mktemp -d)"
containers=(myzql-tls myzql-wronghost myzql-plain)

cleanup() {
    for container in "${containers[@]}"; do
        docker rm -f "$container" > /dev/null 2>&1 || true
    done
    rm -rf "$work_dir"
}
trap cleanup EXIT

# A certificate is only usable for a host name if the name is in the subject
# alternative names, which MySQL requires in a server certificate anyway.
generate_cert() {
    local name="$1" subject="$2" san="$3"
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "$work_dir/$name-key.pem" -out "$work_dir/$name.csr" \
        -subj "$subject" > /dev/null 2>&1
    openssl x509 -req -in "$work_dir/$name.csr" -sha256 -days 3650 \
        -CA "$work_dir/ca.pem" -CAkey "$work_dir/ca-key.pem" -CAcreateserial \
        -extfile <(printf 'subjectAltName=%s\n' "$san") \
        -out "$work_dir/$name-cert.pem" > /dev/null 2>&1
}

echo "generating certificates in $work_dir"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "$work_dir/ca-key.pem" -out "$work_dir/ca.pem" \
    -subj "/CN=myzql test CA" > /dev/null 2>&1
generate_cert server "/CN=localhost" "DNS:localhost,IP:127.0.0.1,IP:::1"
generate_cert wronghost "/CN=wronghost.example.com" "DNS:wronghost.example.com"

echo "building $image"
docker build --quiet --tag "$image" --file "$repo_root/integration_tests/tls/Dockerfile" "$work_dir" > /dev/null

cert_args=(--ssl-ca=/etc/mysql/test-certs/ca.pem)
echo "starting the servers"
docker run --name myzql-tls --detach --rm \
    --env MYSQL_ROOT_PASSWORD=password --publish "$tls_port:3306" "$image" \
    "${cert_args[@]}" \
    --ssl-cert=/etc/mysql/test-certs/server-cert.pem \
    --ssl-key=/etc/mysql/test-certs/server-key.pem > /dev/null
docker run --name myzql-wronghost --detach --rm \
    --env MYSQL_ROOT_PASSWORD=password --publish "$wrong_host_port:3306" "$image" \
    "${cert_args[@]}" \
    --ssl-cert=/etc/mysql/test-certs/wronghost-cert.pem \
    --ssl-key=/etc/mysql/test-certs/wronghost-key.pem > /dev/null
docker run --name myzql-plain --detach --rm \
    --env MARIADB_ROOT_PASSWORD=password --publish "$notls_port:3306" \
    mariadb --skip-ssl > /dev/null

# The MariaDB client refuses to connect without TLS against a server that runs
# with --skip-ssl, so the caller passes --skip-ssl for the server without TLS.
wait_for_server() {
    local container="$1" password="$2" attempt binary
    shift 2
    for attempt in $(seq 1 60); do
        # the MySQL image ships `mysqladmin`, the MariaDB image `mariadb-admin`
        for binary in mysqladmin mariadb-admin; do
            if docker exec "$container" "$binary" ping --user=root --password="$password" \
                --silent "$@" > /dev/null 2>&1; then
                return 0
            fi
        done
        sleep 2
    done
    echo "error: $container did not become ready" >&2
    docker logs --tail 20 "$container" >&2
    return 1
}

wait_for_server myzql-tls password
wait_for_server myzql-wronghost password
wait_for_server myzql-plain password --skip-ssl

echo "running the TLS integration tests"
cd "$repo_root"
zig build integration_test -Dskip-stress=true \
    -Dtls-ca-path="$work_dir/ca.pem" \
    -Dtls-wrong-host-port="$wrong_host_port" \
    -Dnotls-port="$notls_port" \
    -Dtest-filter="tls - " "$@"
