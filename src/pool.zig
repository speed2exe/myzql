const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Config = @import("./config.zig").Config;
const Conn = @import("./conn.zig").Conn;
const result = @import("./result.zig");
const QueryResult = result.QueryResult;
const PrepareResult = result.PrepareResult;
const PreparedStatement = result.PreparedStatement;
const TextResultRow = result.TextResultRow;
const BinaryResultRow = result.BinaryResultRow;

/// Configuration options for the connection pool.
pub const Options = struct {
    /// Maximum number of connections the pool will create.
    /// When all connections are in use, `acquire` returns `error.PoolExhausted`.
    max_size: usize = 10,
};

/// A thread-safe connection pool for MySQL/MariaDB connections.
///
/// Usage:
/// ```zig
/// var pool = try Pool.init(allocator, &config, .{ .max_size = 10 });
/// defer pool.deinit(io);
///
/// var mc = try pool.acquireManaged(io);
/// defer mc.deinit(io);
/// const result = try mc.query(io, "SELECT 1");
/// ```
///
/// `Pool` must not be moved or copied after initialization
/// (internal connections store pointers to pool-owned config strings).
pub const Pool = struct {
    allocator: Allocator,

    /// Owned copy of config with all string fields cloned into pool-owned memory.
    owned_config: OwnedConfig,

    /// List of idle connections available for reuse.
    idle: std.ArrayList(*Conn),

    /// Total connections created (idle + in-use).
    total_count: usize,

    /// Upper bound on total connections.
    max_size: usize,

    /// Protects `idle` and `total_count` from concurrent access.
    mutex: std.Io.Mutex,

    /// Owned copy of `Config` with heap-allocated string fields.
    /// Required because `Conn.init` borrows config slices for the connection's lifetime.
    const OwnedConfig = struct {
        username: [:0]u8,
        password: []u8,
        database: [:0]u8,
        /// Copy of the string `Config.address` refers to, either a host name or
        /// a unix socket path. Empty for `.ip`, which owns no memory.
        address_data: []u8,
        value: Config,

        fn deinit(oc: *OwnedConfig, allocator: Allocator) void {
            allocator.free(oc.username);
            allocator.free(oc.password);
            allocator.free(oc.database);
            allocator.free(oc.address_data);
        }
    };

    /// Initialize the connection pool.
    ///
    /// Clones the string fields of `config`, as well as the memory held by
    /// `config.address` (host name or unix socket path), into pool-owned memory
    /// so the original `config` does not need to outlive the pool.
    /// No connections are created until `acquire` is called.
    pub fn init(allocator: Allocator, config: *const Config, options: Options) !Pool {
        const username = try allocator.dupeSentinel(u8, config.username, 0);
        errdefer allocator.free(username);

        const password = try allocator.dupe(u8, config.password);
        errdefer allocator.free(password);

        const database = try allocator.dupeSentinel(u8, config.database, 0);
        errdefer allocator.free(database);

        // A host name or socket path may point into memory owned by the caller,
        // e.g. the storage of a `Config.fromUrl`, so it is cloned as well
        var address_data: []u8 = &.{};
        errdefer allocator.free(address_data);

        var address = config.address;
        switch (address) {
            .host => |host| {
                address_data = try allocator.dupe(u8, host.name.bytes);
                address = .{ .host = .{ .name = .{ .bytes = address_data }, .port = host.port } };
            },
            .unix => |unix| {
                address_data = try allocator.dupe(u8, unix.path);
                address = .{ .unix = try std.Io.net.UnixAddress.init(address_data) };
            },
            .ip => {},
        }

        const owned_config = OwnedConfig{
            .username = username,
            .password = password,
            .database = database,
            .address_data = address_data,
            .value = .{
                .username = username,
                .address = address,
                .password = password,
                .database = database,
                .collation = config.collation,
                .client_found_rows = config.client_found_rows,
                .ssl = config.ssl,
                .multi_statements = config.multi_statements,
            },
        };

        return .{
            .allocator = allocator,
            .owned_config = owned_config,
            .idle = std.ArrayList(*Conn).empty,
            .total_count = 0,
            .max_size = options.max_size,
            .mutex = std.Io.Mutex.init,
        };
    }

    /// Close all idle connections and release pool resources.
    ///
    /// Any connections currently in use (acquired but not yet released) will
    /// not be closed by this call — the caller is responsible for releasing
    /// them first. A warning is logged if connections remain outstanding.
    pub fn deinit(p: *Pool, io: std.Io) void {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);

        for (p.idle.items) |conn| {
            conn.deinit(p.allocator, io);
            p.allocator.destroy(conn);
            p.total_count -= 1;
        }
        p.idle.deinit(p.allocator);

        if (p.total_count > 0) {
            std.log.warn("pool deinit with {d} outstanding connection(s) still in use", .{p.total_count});
        }

        p.owned_config.deinit(p.allocator);
    }

    /// Borrow a connection from the pool.
    ///
    /// Returns an idle connection if available (after a health check), or
    /// creates a new one if under `max_size`. The caller **must** call
    /// `release` to return the connection to the pool when done.
    ///
    /// Returns `error.PoolExhausted` if all connections are in use and
    /// `max_size` has been reached.
    pub fn acquire(p: *Pool, io: std.Io) !*Conn {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);

        // Try to reuse an idle connection
        while (p.idle.pop()) |conn| {
            if (!conn.connected) {
                conn.deinit(p.allocator, io);
                p.allocator.destroy(conn);
                p.total_count -= 1;
                continue;
            }
            // Health check — if ping fails, close and try the next one
            conn.ping(io) catch {
                conn.deinit(p.allocator, io);
                p.allocator.destroy(conn);
                p.total_count -= 1;
                continue;
            };
            return conn;
        }

        // No idle connections available — create a new one
        if (p.total_count >= p.max_size) {
            return error.PoolExhausted;
        }

        const conn = try p.allocator.create(Conn);
        errdefer p.allocator.destroy(conn);

        conn.* = try Conn.init(p.allocator, io, &p.owned_config.value);
        p.total_count += 1;
        return conn;
    }

    /// Return a connection to the pool.
    ///
    /// Resets the connection's internal state (buffers, sequence id, result
    /// metadata) so it's ready for the next user. If the connection has died
    /// (`connected == false`), it is closed and freed instead of being
    /// returned to the pool.
    pub fn release(p: *Pool, conn: *Conn, io: std.Io) void {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);

        if (!conn.connected) {
            // Connection died while in use — close and free
            conn.deinit(p.allocator, io);
            p.allocator.destroy(conn);
            p.total_count -= 1;
            return;
        }

        // Reset connection to a clean state for the next user
        conn.writer.reset();
        conn.reader.pos = 0;
        conn.reader.len = 0;
        conn.sequence_id = 0;
        conn.result_meta.raw.clearRetainingCapacity();
        conn.result_meta.col_defs.clearRetainingCapacity();

        p.idle.append(p.allocator, conn) catch {
            // Out of memory — close the connection rather than leaking
            conn.deinit(p.allocator, io);
            p.allocator.destroy(conn);
            p.total_count -= 1;
        };
    }

    /// Borrow a connection wrapped in a `ManagedConn`.
    ///
    /// `ManagedConn.deinit(io)` automatically returns the connection to the pool.
    /// Use `defer mc.deinit(io)` to ensure the connection is always released.
    ///
    /// Convenience methods on `ManagedConn` forward to the underlying `Conn`.
    pub fn acquireManaged(p: *Pool, io: std.Io) !ManagedConn {
        return ManagedConn{
            .pool = p,
            .conn = try p.acquire(io),
        };
    }

    /// Returns the number of idle connections currently in the pool.
    pub fn idleCount(p: *Pool, io: std.Io) usize {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        return p.idle.items.len;
    }

    /// Returns the total number of connections managed by the pool
    /// (idle + in-use).
    pub fn totalCount(p: *Pool, io: std.Io) usize {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        return p.total_count;
    }

    /// A managed connection that automatically returns itself to the pool on `deinit`.
    ///
    /// Always use `defer managed_conn.deinit(io)` after acquiring to prevent
    /// connection leaks.
    pub const ManagedConn = struct {
        pool: *Pool,
        conn: *Conn,

        /// Return the connection to the pool.
        pub fn deinit(m: *ManagedConn, io: std.Io) void {
            m.pool.release(m.conn, io);
        }

        /// Access the underlying raw `Conn` for operations not covered by
        /// convenience methods.
        pub fn raw(m: *ManagedConn) *Conn {
            return m.conn;
        }

        /// Send a ping to verify the connection is alive.
        pub fn ping(m: *ManagedConn, io: std.Io) !void {
            return m.conn.ping(io);
        }

        /// Execute a text query. Returns `QueryResult` (`.ok`, `.err`, or `.rows` if the query returns rows).
        pub fn query(m: *ManagedConn, io: std.Io, query_string: []const u8) !QueryResult(TextResultRow) {
            return m.conn.query(io, query_string);
        }

        /// Prepare a SQL statement for execution.
        pub fn prepare(m: *ManagedConn, allocator: Allocator, io: std.Io, query_string: []const u8) !PrepareResult {
            return m.conn.prepare(allocator, io, query_string);
        }

        /// Execute a prepared statement that does not return rows.
        pub fn execute(m: *ManagedConn, io: std.Io, prep_stmt: *const PreparedStatement, params: anytype) !QueryResult(BinaryResultRow) {
            return m.conn.execute(io, prep_stmt, params);
        }
    };
};

const testing = std.testing;

test "init - clones the config into pool-owned memory" {
    var pool: Pool = undefined;
    {
        var url_config = try Config.fromUrl(testing.allocator, "mysql://alice:secret@localhost:3307/db?multiStatements=true");
        defer url_config.deinit(testing.allocator);

        pool = try Pool.init(testing.allocator, &url_config.value, .{});
    }
    // the pool must not refer to the (now freed) storage of `url_config`
    defer pool.deinit(testing.io);

    const config = pool.owned_config.value;
    try testing.expectEqualStrings("alice", config.username);
    try testing.expectEqualStrings("secret", config.password);
    try testing.expectEqualStrings("db", config.database);
    try testing.expectEqualStrings("localhost", config.address.host.name.bytes);
    try testing.expectEqual(3307, config.address.host.port);
    try testing.expectEqual(true, config.multi_statements);
}

test "init - clones the unix socket path into pool-owned memory" {
    var pool: Pool = undefined;
    {
        var url_config = try Config.fromUrl(testing.allocator, "mysql://root:secret@/db?socket=%2Ftmp%2Fmysql.sock");
        defer url_config.deinit(testing.allocator);

        pool = try Pool.init(testing.allocator, &url_config.value, .{});
    }
    // the pool must not refer to the (now freed) storage of `url_config`
    defer pool.deinit(testing.io);

    const config = pool.owned_config.value;
    try testing.expectEqualStrings("root", config.username);
    try testing.expectEqualStrings("db", config.database);
    switch (config.address) {
        .unix => |unix| try testing.expectEqualStrings("/tmp/mysql.sock", unix.path),
        else => return error.TestExpectedUnixAddress,
    }
}
