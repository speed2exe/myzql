const std = @import("std");
const constants = @import("./constants.zig");

/// Port used by a connection URL that does not specify one.
pub const default_port: u16 = 3306;

/// Configuration for a MySQL/MariaDB connection.
pub const Config = struct {
    /// MySQL username. Default: "root"
    username: [:0]const u8 = "root",
    /// Server address. Default: 127.0.0.1:3306 (IPv4)
    address: Address = .{ .ip = std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") catch unreachable },
    /// MySQL password. Default: ""
    password: []const u8 = "",
    /// Default database to use. Default: ""
    database: [:0]const u8 = "",
    collation: u8 = constants.utf8mb4_general_ci,

    /// Return number of matching rows instead of rows changed. Default: false
    client_found_rows: bool = false,
    /// Enable SSL. Default: false
    ///
    /// The connection is only established over TLS; an error is returned if the
    /// server does not support TLS. Unix sockets are already a secure channel,
    /// so this option is ignored for them.
    ssl: bool = false,
    /// Verify the server's certificate, i.e. that it is signed by a trusted CA
    /// and issued for the host that was connected to. Only used when `ssl` is
    /// true. Default: true
    ///
    /// Disabling verification still encrypts the connection, but the server is
    /// not authenticated, which makes the connection vulnerable to
    /// man-in-the-middle attacks.
    ssl_verify: bool = true,
    /// PEM file with the CA certificates used to verify the server when `ssl`
    /// is true. Default: null, which uses the CA certificates installed on the
    /// system
    ssl_ca: ?[]const u8 = null,
    /// Allow multiple statements in a single query. Default: false
    multi_statements: bool = false,

    pub fn capability_flags(config: *const Config) u32 {
        // zig fmt: off
        var flags: u32 = constants.CLIENT_PROTOCOL_41
                       | constants.CLIENT_PLUGIN_AUTH
                       | constants.CLIENT_SECURE_CONNECTION
                       | constants.CLIENT_DEPRECATE_EOF
                       // TODO: Support more
                       ;
        // zig fmt: on
        if (config.client_found_rows) {
            flags |= constants.CLIENT_FOUND_ROWS;
        }
        if (config.ssl) {
            flags |= constants.CLIENT_SSL;
        }
        if (config.multi_statements) {
            flags |= constants.CLIENT_MULTI_STATEMENTS;
        }
        if (config.database.len > 0) {
            flags |= constants.CLIENT_CONNECT_WITH_DB;
        }
        return flags;
    }

    /// Parse a MySQL connection URL into an owned `Config`:
    ///
    ///     mysql://[user[:password]@][host[:port]][/database][?parameter=value&...]
    ///
    /// `mysql://user:pass@/db?socket=/var/run/mysqld/mysqld.sock` connects
    /// through a unix domain socket, everything else connects over TCP. A host
    /// that is not an IP address is resolved when the connection is established.
    /// `mariadb://` is accepted as an alias of `mysql://`.
    ///
    /// Supported parameters (keys are matched case-insensitively):
    /// - `socket=<path>`: unix domain socket path, see `Address.unix`
    /// - `charset=<name>`: connection collation, e.g. `charset=utf8mb4`
    /// - `clientFoundRows=<bool>`: see `client_found_rows`
    /// - `multiStatements=<bool>`: see `multi_statements`
    /// - `ssl=<bool>` / `tls=<bool>`: see `ssl`
    /// - `sslVerify=<bool>` / `ssl_verify=<bool>`: see `ssl_verify`
    /// - `sslCa=<path>` / `ssl_ca=<path>`: see `ssl_ca`
    ///
    /// Booleans accept `true`, `false`, `1` and `0`. A parameter with an empty
    /// value keeps the default, which allows leaving placeholders like
    /// `?charset=` in a URL template. Every component may be percent-encoded,
    /// e.g. `mysql://us%40r:p%40ss@localhost/db`; a `%00` byte is rejected with
    /// `error.InvalidUrl` because usernames and database names are NUL
    /// terminated.
    ///
    /// The returned `UrlConfig` owns the decoded strings that `Config` refers
    /// to, so it must be kept alive while the config is in use and released
    /// with `UrlConfig.deinit`.
    pub fn fromUrl(allocator: std.mem.Allocator, url: []const u8) !UrlConfig {
        return UrlConfig.parse(allocator, url);
    }
};

pub const Address = union(enum) {
    /// IP address to connect to directly. Carries the port.
    ip: std.Io.net.IpAddress,
    /// Host name to resolve at connect time.
    host: Host,
    /// Unix domain socket to connect through.
    unix: std.Io.net.UnixAddress,

    pub const Host = struct {
        name: std.Io.net.HostName,
        port: u16 = default_port,
    };

    /// Return the host name or IP address literal of the address, without the
    /// port and without the brackets of IPv6 literals. This is the name used
    /// for TLS (SNI and certificate verification).
    /// The returned slice points into `buffer` when the address is an IP
    /// address, and into the address itself when it is a host name.
    pub fn hostName(a: Address, buffer: *[std.Io.net.HostName.max_len]u8) ![]const u8 {
        return switch (a) {
            .host => |host| host.name.bytes,
            .ip => |ip| switch (ip) {
                .ip4 => |ip4| std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
                    ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
                }),
                .ip6 => |ip6| std.fmt.bufPrint(buffer, "{f}", .{
                    std.Io.net.Ip6Address.Unresolved{
                        .bytes = ip6.bytes,
                        .interface_name = null,
                    },
                }),
            },
            .unix => error.UnixSocketHasNoHostName,
        };
    }
};

/// A `Config` together with the memory backing its decoded strings.
/// Obtained from `Config.fromUrl`, released with `deinit`.
pub const UrlConfig = struct {
    /// The parsed configuration. Refers to `storage`, do not use after `deinit`.
    value: Config,
    /// Backing memory of the strings referenced by `value`.
    storage: []u8,

    pub fn deinit(u: *UrlConfig, allocator: std.mem.Allocator) void {
        allocator.free(u.storage);
        u.* = undefined;
    }

    pub fn parse(allocator: std.mem.Allocator, url: []const u8) !UrlConfig {
        const uri = try std.Uri.parse(url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "mysql") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "mariadb"))
        {
            return error.UnsupportedUrlScheme;
        }

        // A decoded component is never longer than its encoded form, so one
        // `url.len` sized buffer holds all of them. The extra bytes leave room
        // for the NUL terminators appended by `Decoder.terminate`.
        const storage = try allocator.alloc(u8, url.len + 8);
        errdefer allocator.free(storage);

        var decoder: Decoder = .{ .buffer = storage };
        var config: Config = .{};

        // userinfo
        if (uri.user) |component| {
            const username = try decoder.decodeComponent(component);
            if (username.len > 0) config.username = try decoder.terminate(username);
        }
        if (uri.password) |component| {
            config.password = decoder.bytes(try decoder.decodeComponent(component));
        }

        // the path names the default database
        const database = decoder.trimSlashes(try decoder.decodeComponent(uri.path));
        if (database.len > 0) config.database = try decoder.terminate(database);

        // query parameters
        var socket: ?[]u8 = null;
        if (uri.query) |component| {
            const query = switch (component) {
                .raw, .percent_encoded => |value| value,
            };
            var parameters = std.mem.splitScalar(u8, query, '&');
            while (parameters.next()) |parameter| {
                if (parameter.len == 0) continue;

                const separator = std.mem.indexOfScalar(u8, parameter, '=') orelse parameter.len;
                const key = parameter[0..separator];
                const encoded_value = if (separator < parameter.len) parameter[separator + 1 ..] else "";
                const value = decoder.bytes(try decoder.decodeComponent(.{ .percent_encoded = encoded_value }));

                const is_known = std.ascii.eqlIgnoreCase(key, "socket") or
                    std.ascii.eqlIgnoreCase(key, "unix_socket") or
                    std.ascii.eqlIgnoreCase(key, "charset") or
                    std.ascii.eqlIgnoreCase(key, "clientFoundRows") or
                    std.ascii.eqlIgnoreCase(key, "client_found_rows") or
                    std.ascii.eqlIgnoreCase(key, "multiStatements") or
                    std.ascii.eqlIgnoreCase(key, "multi_statements") or
                    std.ascii.eqlIgnoreCase(key, "ssl") or
                    std.ascii.eqlIgnoreCase(key, "tls") or
                    std.ascii.eqlIgnoreCase(key, "sslVerify") or
                    std.ascii.eqlIgnoreCase(key, "ssl_verify") or
                    std.ascii.eqlIgnoreCase(key, "sslCa") or
                    std.ascii.eqlIgnoreCase(key, "ssl_ca");
                if (!is_known) return error.UnknownUrlParameter;

                // An empty value is treated as an absent parameter, so that
                // placeholders like `?charset=` can be left in a URL template
                if (value.len == 0) continue;

                if (std.ascii.eqlIgnoreCase(key, "socket") or std.ascii.eqlIgnoreCase(key, "unix_socket")) {
                    socket = value;
                } else if (std.ascii.eqlIgnoreCase(key, "charset")) {
                    config.collation = try collationFromCharset(value);
                } else if (std.ascii.eqlIgnoreCase(key, "clientFoundRows") or
                    std.ascii.eqlIgnoreCase(key, "client_found_rows"))
                {
                    config.client_found_rows = try parseBool(value);
                } else if (std.ascii.eqlIgnoreCase(key, "multiStatements") or
                    std.ascii.eqlIgnoreCase(key, "multi_statements"))
                {
                    config.multi_statements = try parseBool(value);
                } else if (std.ascii.eqlIgnoreCase(key, "ssl") or std.ascii.eqlIgnoreCase(key, "tls")) {
                    config.ssl = try parseBool(value);
                } else if (std.ascii.eqlIgnoreCase(key, "sslVerify") or
                    std.ascii.eqlIgnoreCase(key, "ssl_verify"))
                {
                    config.ssl_verify = try parseBool(value);
                } else if (std.ascii.eqlIgnoreCase(key, "sslCa") or std.ascii.eqlIgnoreCase(key, "ssl_ca")) {
                    config.ssl_ca = value;
                }
            }
        }

        // address
        if (socket) |path| {
            config.address = .{ .unix = try std.Io.net.UnixAddress.init(path) };
        } else {
            const host = if (uri.host) |component|
                decoder.bytes(try decoder.decodeComponent(component))
            else
                "";
            config.address = try addressFromHost(host, uri.port orelse default_port);
        }

        return .{ .value = config, .storage = storage };
    }
};

/// Build an `Address` from the host and port of a URL.
fn addressFromHost(host: []const u8, port: u16) !Address {
    // IPv6 literals are wrapped in brackets in URLs
    const unbracketed = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;

    if (unbracketed.len == 0) return error.UrlMissingHost;
    if (port == 0) return error.InvalidPort;

    if (std.Io.net.IpAddress.parse(unbracketed, port)) |ip| {
        return .{ .ip = ip };
    } else |_| {}

    return .{ .host = .{
        .name = std.Io.net.HostName.init(unbracketed) catch return error.InvalidUrlHost,
        .port = port,
    } };
}

fn parseBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidUrlParameterValue;
}

/// Map a character set name to the id of its default collation.
fn collationFromCharset(charset: []const u8) !u8 {
    var buffer: [64]u8 = undefined;
    if (charset.len > buffer.len) return error.UnknownCharset;
    const lowercase = std.ascii.lowerString(&buffer, charset);

    if (collations.get(lowercase)) |id| return id;

    // A character set is named after its default collation, except for a few
    // sets like latin1 that default to e.g. latin1_swedish_ci. Fall back to the
    // collations that every character set provides.
    const name = if (std.mem.eql(u8, lowercase, "utf8")) "utf8mb3" else lowercase;

    for ([_][]const u8{ "_general_ci", "_bin" }) |suffix| {
        var name_buffer: [64]u8 = undefined;
        const collation = std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ name, suffix }) catch return error.UnknownCharset;
        if (collations.get(collation)) |id| return id;
    }

    return error.UnknownCharset;
}

/// Collation name to id, derived from the collation constants.
const collations = blk: {
    @setEvalBranchQuota(20_000);
    const names = @typeInfo(constants).@"struct".decl_names;
    var kvs: [names.len]struct { []const u8, u8 } = undefined;
    var len: usize = 0;
    for (names) |name| {
        if (@TypeOf(@field(constants, name)) != u8) continue;
        if (!isCollationName(name)) continue;
        kvs[len] = .{ name, @field(constants, name) };
        len += 1;
    }
    break :blk std.StaticStringMap(u8).initComptime(kvs[0..len]);
};

fn isCollationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "binary") or
        std.mem.endsWith(u8, name, "_ci") or
        std.mem.endsWith(u8, name, "_cs") or
        std.mem.endsWith(u8, name, "_bin");
}

/// Bump allocator for the decoded strings of a parsed URL.
const Decoder = struct {
    buffer: []u8,
    pos: usize = 0,

    const Span = struct { start: usize, len: usize };

    fn decodeComponent(d: *Decoder, component: std.Uri.Component) !Span {
        switch (component) {
            .raw => |raw| return d.copy(raw),
            .percent_encoded => |encoded| {
                const span = try d.copy(encoded);
                const source = d.bytes(span);
                // Decoding happens in place and is right-aligned within `source`
                const decoded = std.Uri.percentDecodeInPlace(source);
                // NUL cannot be stored in a sentinel-terminated string
                if (std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidUrl;
                return .{ .start = span.start + (source.len - decoded.len), .len = decoded.len };
            },
        }
    }

    fn copy(d: *Decoder, source: []const u8) !Span {
        if (source.len > d.buffer.len - d.pos) return error.UrlTooLong;
        const span: Span = .{ .start = d.pos, .len = source.len };
        @memcpy(d.bytes(span), source);
        d.pos += source.len;
        return span;
    }

    fn bytes(d: *Decoder, span: Span) []u8 {
        return d.buffer[span.start..][0..span.len];
    }

    /// Append a NUL terminator to `span` and return it as a sentinel slice.
    fn terminate(d: *Decoder, span: Span) ![:0]u8 {
        if (span.start + span.len >= d.buffer.len) return error.UrlTooLong;
        d.buffer[span.start + span.len] = 0;
        d.pos = span.start + span.len + 1;
        return d.buffer[span.start..][0..span.len :0];
    }

    /// Remove the leading and trailing '/' separators of a span.
    fn trimSlashes(d: *Decoder, span: Span) Span {
        var trimmed = span;
        while (trimmed.len > 0 and d.buffer[trimmed.start] == '/') {
            trimmed.start += 1;
            trimmed.len -= 1;
        }
        while (trimmed.len > 0 and d.buffer[trimmed.start + trimmed.len - 1] == '/') trimmed.len -= 1;
        return trimmed;
    }
};

const testing = std.testing;

fn expectHost(config: Config, name: []const u8, port: u16) !void {
    switch (config.address) {
        .host => |host| {
            try testing.expectEqualStrings(name, host.name.bytes);
            try testing.expectEqual(port, host.port);
        },
        else => return error.TestExpectedHostAddress,
    }
}

test "fromUrl - defaults" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost");
    defer url_config.deinit(testing.allocator);
    const config = url_config.value;

    try testing.expectEqualStrings("root", config.username);
    try testing.expectEqualStrings("", config.password);
    try testing.expectEqualStrings("", config.database);
    try expectHost(config, "localhost", default_port);
    try testing.expectEqual(constants.utf8mb4_general_ci, config.collation);
    try testing.expectEqual(false, config.client_found_rows);
    try testing.expectEqual(false, config.multi_statements);
    try testing.expectEqual(false, config.ssl);
}

test "fromUrl - full url" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://alice:s3cret@127.0.0.1:3307/mydb" ++
        "?charset=utf8mb4_bin&clientFoundRows=true&multiStatements=1&ssl=false");
    defer url_config.deinit(testing.allocator);
    const config = url_config.value;

    try testing.expectEqualStrings("alice", config.username);
    try testing.expectEqualStrings("s3cret", config.password);
    try testing.expectEqualStrings("mydb", config.database);
    try testing.expectEqual(constants.utf8mb4_bin, config.collation);
    try testing.expectEqual(true, config.client_found_rows);
    try testing.expectEqual(true, config.multi_statements);
    try testing.expectEqual(false, config.ssl);

    const expected = try std.Io.net.IpAddress.parse("127.0.0.1", 3307);
    switch (config.address) {
        .ip => |ip| try testing.expect(ip.eql(&expected)),
        else => return error.TestExpectedIpAddress,
    }
}

test "fromUrl - percent encoded user and password" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://us%40r:p%2Fss%3Aword@localhost/db");
    defer url_config.deinit(testing.allocator);

    try testing.expectEqualStrings("us@r", url_config.value.username);
    try testing.expectEqualStrings("p/ss:word", url_config.value.password);
    try expectHost(url_config.value, "localhost", default_port);
}

test "fromUrl - percent encoded database" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost/my%20db");
    defer url_config.deinit(testing.allocator);

    try testing.expectEqualStrings("my db", url_config.value.database);
}

test "fromUrl - empty userinfo keeps defaults" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://@localhost/db");
    defer url_config.deinit(testing.allocator);

    try testing.expectEqualStrings("root", url_config.value.username);
    try testing.expectEqualStrings("", url_config.value.password);
    try testing.expectEqualStrings("db", url_config.value.database);
}

test "fromUrl - ipv4 and ipv6 literals" {
    var v4 = try Config.fromUrl(testing.allocator, "mysql://192.168.1.2/db");
    defer v4.deinit(testing.allocator);
    const expected_v4 = try std.Io.net.IpAddress.parse("192.168.1.2", default_port);
    switch (v4.value.address) {
        .ip => |ip| try testing.expect(ip.eql(&expected_v4)),
        else => return error.TestExpectedIpAddress,
    }

    var v6 = try Config.fromUrl(testing.allocator, "mysql://[::1]:3307/db");
    defer v6.deinit(testing.allocator);
    const expected_v6 = try std.Io.net.IpAddress.parse("::1", 3307);
    switch (v6.value.address) {
        .ip => |ip| try testing.expect(ip.eql(&expected_v6)),
        else => return error.TestExpectedIpAddress,
    }
}

test "fromUrl - unix socket" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://root@/db?socket=%2Fvar%2Frun%2Fmysqld%2Fmysqld.sock");
    defer url_config.deinit(testing.allocator);

    switch (url_config.value.address) {
        .unix => |unix| try testing.expectEqualStrings("/var/run/mysqld/mysqld.sock", unix.path),
        else => return error.TestExpectedUnixAddress,
    }
    try testing.expectEqualStrings("db", url_config.value.database);
}

test "fromUrl - charset" {
    const cases = [_]struct { []const u8, u8 }{
        .{ "utf8mb4", constants.utf8mb4_general_ci },
        .{ "UTF8MB4", constants.utf8mb4_general_ci },
        .{ "utf8mb4_bin", constants.utf8mb4_bin },
        .{ "utf8", constants.utf8mb3_general_ci },
        .{ "latin1", constants.latin1_general_ci },
    };
    for (cases) |case| {
        const url = try std.fmt.allocPrint(testing.allocator, "mysql://localhost/db?charset={s}", .{case[0]});
        defer testing.allocator.free(url);

        var url_config = try Config.fromUrl(testing.allocator, url);
        defer url_config.deinit(testing.allocator);
        try testing.expectEqual(case[1], url_config.value.collation);
    }
}

test "fromUrl - mariadb scheme and parameter aliases" {
    var url_config = try Config.fromUrl(testing.allocator, "mariadb://localhost/db?unix_socket=&client_found_rows=TRUE&tls=0");
    defer url_config.deinit(testing.allocator);
    const config = url_config.value;

    try expectHost(config, "localhost", default_port);
    try testing.expectEqual(true, config.client_found_rows);
    try testing.expectEqual(false, config.ssl);
}

test "fromUrl - database with slashes" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost//db/");
    defer url_config.deinit(testing.allocator);

    try testing.expectEqualStrings("db", url_config.value.database);
}

test "fromUrl - errors" {
    const cases = [_]struct { []const u8, anyerror }{
        .{ "postgres://localhost/db", error.UnsupportedUrlScheme },
        .{ "localhost/db", error.InvalidFormat },
        .{ "https://localhost/db", error.UnsupportedUrlScheme },
        .{ "mysql:///db", error.UrlMissingHost },
        .{ "mysql://localhost/db?bogus=1", error.UnknownUrlParameter },
        .{ "mysql://localhost/db?ssl=yes", error.InvalidUrlParameterValue },
        .{ "mysql://localhost/db?charset=bogus", error.UnknownCharset },
        .{ "mysql://localhost:0/db", error.InvalidPort },
    };
    for (cases) |case| {
        try testing.expectError(case[1], Config.fromUrl(testing.allocator, case[0]));
    }
}

test "fromUrl - empty parameter values keep the defaults" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost/db?socket=&charset=&multiStatements=&ssl=&clientFoundRows=");
    defer url_config.deinit(testing.allocator);
    const config = url_config.value;

    try expectHost(config, "localhost", default_port);
    try testing.expectEqual(constants.utf8mb4_general_ci, config.collation);
    try testing.expectEqual(false, config.multi_statements);
    try testing.expectEqual(false, config.client_found_rows);
    try testing.expectEqual(false, config.ssl);

    // an empty key is still an unknown parameter
    try testing.expectError(error.UnknownUrlParameter, Config.fromUrl(testing.allocator, "mysql://localhost/db?bogus="));
}

test "fromUrl - separators between parameters are optional" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost/db?&&charset=utf8mb4&&");
    defer url_config.deinit(testing.allocator);

    try testing.expectEqual(constants.utf8mb4_general_ci, url_config.value.collation);
}

test "fromUrl - tls parameters" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost/db?ssl=1&sslVerify=false&sslCa=%2Fetc%2Fssl%2Fca.pem");
    defer url_config.deinit(testing.allocator);
    const config = url_config.value;

    try testing.expectEqual(true, config.ssl);
    try testing.expectEqual(false, config.ssl_verify);
    try testing.expectEqualStrings("/etc/ssl/ca.pem", config.ssl_ca.?);
}

test "fromUrl - tls parameter aliases" {
    var url_config = try Config.fromUrl(testing.allocator, "mysql://localhost/db?tls=1&ssl_verify=true&ssl_ca=/tmp/ca.pem");
    defer url_config.deinit(testing.allocator);
    const config = url_config.value;

    try testing.expectEqual(true, config.ssl);
    try testing.expectEqual(true, config.ssl_verify);
    try testing.expectEqualStrings("/tmp/ca.pem", config.ssl_ca.?);
}

test "tls defaults" {
    const config: Config = .{};

    try testing.expectEqual(false, config.ssl);
    // Server verification is on by default and the CA file is optional
    try testing.expectEqual(true, config.ssl_verify);
    try testing.expectEqual(null, config.ssl_ca);
}

test "capability_flags - CLIENT_SSL is only set when ssl is enabled" {
    var config: Config = .{};
    try testing.expectEqual(0, config.capability_flags() & constants.CLIENT_SSL);

    config.ssl = true;
    try testing.expectEqual(constants.CLIENT_SSL, config.capability_flags() & constants.CLIENT_SSL);
}

test "Address.hostName" {
    var buffer: [std.Io.net.HostName.max_len]u8 = undefined;

    const host: Address = .{ .host = .{
        .name = std.Io.net.HostName.init("db.example.com") catch unreachable,
        .port = 3306,
    } };
    try testing.expectEqualStrings("db.example.com", try host.hostName(&buffer));

    const ip4: Address = .{ .ip = std.Io.net.IpAddress.parseLiteral("192.168.1.2:3306") catch unreachable };
    try testing.expectEqualStrings("192.168.1.2", try ip4.hostName(&buffer));

    // IPv6 literals are returned without the brackets that URLs require
    const ip6: Address = .{ .ip = std.Io.net.IpAddress.parseLiteral("[2001:db8::1]:3306") catch unreachable };
    try testing.expectEqualStrings("2001:db8::1", try ip6.hostName(&buffer));

    const unix: Address = .{ .unix = std.Io.net.UnixAddress.init("/tmp/mysql.sock") catch unreachable };
    try testing.expectError(error.UnixSocketHasNoHostName, unix.hostName(&buffer));
}
