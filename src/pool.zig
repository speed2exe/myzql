const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Config = @import("./config.zig").Config;
const Conn = @import("./conn.zig").Conn;
const result = @import("./result.zig");
const QueryResult = result.QueryResult;
const QueryResultRows = result.QueryResultRows;
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
/// var pool = try Pool.init(allocator, io, &config, .{ .max_size = 10 });
/// defer pool.deinit();
///
/// var mc = try pool.acquireManaged();
/// defer mc.deinit();
/// const result = try mc.query("SELECT 1");
/// ```
///
/// `Pool` must not be moved or copied after initialization
/// (internal connections store pointers to pool-owned config strings).
pub const Pool = struct {
    allocator: Allocator,
    io: Io,

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
        value: Config,

        fn deinit(oc: *OwnedConfig, allocator: Allocator) void {
            allocator.free(oc.username);
            allocator.free(oc.password);
            allocator.free(oc.database);
        }
    };

    /// Initialize the connection pool.
    ///
    /// Clones string fields from `config` into pool-owned memory so the
    /// original `config` does not need to outlive the pool.
    /// No connections are created until `acquire` is called.
    pub fn init(allocator: Allocator, io: Io, config: *const Config, options: Options) !Pool {
        const username = try allocator.dupeSentinel(u8, config.username, 0);
        errdefer allocator.free(username);

        const password = try allocator.dupe(u8, config.password);
        errdefer allocator.free(password);

        const database = try allocator.dupeSentinel(u8, config.database, 0);
        errdefer allocator.free(database);

        const owned_config = OwnedConfig{
            .username = username,
            .password = password,
            .database = database,
            .value = .{
                .username = username,
                .address = config.address,
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
            .io = io,
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
    pub fn deinit(p: *Pool) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);

        for (p.idle.items) |conn| {
            conn.deinit(p.allocator, p.io);
            p.allocator.destroy(conn);
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
    pub fn acquire(p: *Pool) !*Conn {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);

        // Try to reuse an idle connection
        while (p.idle.pop()) |conn| {
            if (!conn.connected) {
                conn.deinit(p.allocator, p.io);
                p.allocator.destroy(conn);
                p.total_count -= 1;
                continue;
            }
            // Health check — if ping fails, close and try the next one
            conn.ping() catch {
                conn.deinit(p.allocator, p.io);
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

        conn.* = try Conn.init(p.allocator, p.io, &p.owned_config.value);
        p.total_count += 1;
        return conn;
    }

    /// Return a connection to the pool.
    ///
    /// Resets the connection's internal state (buffers, sequence id, result
    /// metadata) so it's ready for the next user. If the connection has died
    /// (`connected == false`), it is closed and freed instead of being
    /// returned to the pool.
    pub fn release(p: *Pool, conn: *Conn) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);

        if (!conn.connected) {
            // Connection died while in use — close and free
            conn.deinit(p.allocator, p.io);
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
            conn.deinit(p.allocator, p.io);
            p.allocator.destroy(conn);
            p.total_count -= 1;
        };
    }

    /// Borrow a connection wrapped in a `ManagedConn`.
    ///
    /// `ManagedConn.deinit()` automatically returns the connection to the pool.
    /// Use `defer mc.deinit()` to ensure the connection is always released.
    ///
    /// Convenience methods on `ManagedConn` forward to the underlying `Conn`
    /// without requiring you to pass `io` explicitly.
    pub fn acquireManaged(p: *Pool) !ManagedConn {
        return ManagedConn{
            .pool = p,
            .conn = try p.acquire(),
        };
    }

    /// Returns the number of idle connections currently in the pool.
    pub fn idleCount(p: *Pool) usize {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.idle.items.len;
    }

    /// Returns the total number of connections managed by the pool
    /// (idle + in-use).
    pub fn totalCount(p: *Pool) usize {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.total_count;
    }

    /// A managed connection that automatically returns itself to the pool on `deinit`.
    ///
    /// Always use `defer managed_conn.deinit()` after acquiring to prevent
    /// connection leaks.
    pub const ManagedConn = struct {
        pool: *Pool,
        conn: *Conn,

        /// Return the connection to the pool.
        pub fn deinit(m: *ManagedConn) void {
            m.pool.release(m.conn);
        }

        /// Access the underlying raw `Conn` for operations not covered by
        /// convenience methods.
        pub fn raw(m: *ManagedConn) *Conn {
            return m.conn;
        }

        /// Send a ping to verify the connection is alive.
        pub fn ping(m: *ManagedConn) !void {
            return m.conn.ping();
        }

        /// Execute a query that does not return rows (INSERT, UPDATE, DELETE, etc.).
        pub fn query(m: *ManagedConn, query_string: []const u8) !QueryResult {
            return m.conn.query(m.pool.io, query_string);
        }

        /// Execute a query that returns rows (SELECT, etc.).
        pub fn queryRows(m: *ManagedConn, allocator: Allocator, query_string: []const u8) !QueryResultRows(TextResultRow) {
            return m.conn.queryRows(allocator, query_string);
        }

        /// Prepare a SQL statement for execution.
        pub fn prepare(m: *ManagedConn, allocator: Allocator, query_string: []const u8) !PrepareResult {
            return m.conn.prepare(allocator, query_string);
        }

        /// Execute a prepared statement that does not return rows.
        pub fn execute(m: *ManagedConn, prep_stmt: *const PreparedStatement, params: anytype) !QueryResult {
            return m.conn.execute(m.pool.io, prep_stmt, params);
        }

        /// Execute a prepared statement that returns rows.
        pub fn executeRows(m: *ManagedConn, allocator: Allocator, prep_stmt: *const PreparedStatement, params: anytype) !QueryResultRows(BinaryResultRow) {
            return m.conn.executeRows(allocator, prep_stmt, params);
        }
    };
};
