//! Per-config logging.
//!
//! The logger is a field of `Config`: every message the library emits on behalf
//! of a connection is handed to the logger of the config that connection was
//! created with, together with that config. A `Config` can be shared by many
//! connections, so a handler can identify the connections that share a sink
//! without being handed each of them.
//!
//! Leaving `Config.logger` alone keeps `default_logger`, which writes the
//! message with `std.log`. Setting it to `null` turns logging off: the message
//! is dropped without even being formatted.

const std = @import("std");
const Config = @import("./config.zig").Config;

/// Severity of a log message. Matches `std.log.Level`.
pub const Level = std.log.Level;

/// Handler for the log messages of a config.
pub const Logger = struct {
    /// Passed back to `logFn` unchanged. Use it to reach your own log sink, or
    /// to share state between configs that use the same `logFn`.
    context: ?*anyopaque = null,
    /// Called for every message emitted on behalf of the config passed as
    /// `config`.
    ///
    /// `config` is null for a message that has no config behind it, e.g. one
    /// emitted by a value that was built by hand.
    ///
    /// Defaults to `defaultLogFn`, so `Logger{}` is a valid logger that writes
    /// with `std.log`.
    logFn: LogFn = defaultLogFn,

    pub const LogFn = *const fn (
        context: ?*anyopaque,
        config: ?*const Config,
        level: Level,
        message: []const u8,
    ) void;
};

/// Logger used when the user does not configure one. This is the default value
/// of `Config.logger`.
pub const default_logger: Logger = .{};

/// Assign this to `Config.logger` to turn logging off, i.e.
/// `config.logger = myzql.logger.silent;`
///
/// It is plain `null`; the constant exists so the intent reads at the call
/// site. Something to log is never emitted for such a config, not even
/// formatted, so it costs nothing.
pub const silent: ?Logger = null;

/// Capacity of the stack buffer used to format a message. Longer messages are
/// truncated.
pub const max_message_len: usize = 1024;

/// Write a message with `std.log`.
///
/// This is the default handler: `context` and `config` are ignored and the
/// message goes to `std.log` as it is. Since messages carry no trailing
/// newline, `std.log` ends the line exactly once.
pub fn defaultLogFn(
    context: ?*anyopaque,
    config: ?*const Config,
    level: Level,
    message: []const u8,
) void {
    _ = context;
    _ = config;
    switch (level) {
        .err => std.log.err("{s}", .{message}),
        .warn => std.log.warn("{s}", .{message}),
        .info => std.log.info("{s}", .{message}),
        .debug => std.log.debug("{s}", .{message}),
    }
}

/// Emit `fmt`/`args` at `level`, through the logger of `config`.
///
/// The message is formatted into a fixed stack buffer and passed to the handler
/// together with `config`. A null `config` has no logger to honour, and a
/// config whose `logger` is null turned logging off, so in both cases nothing is
/// formatted and nothing is emitted.
pub fn log(
    config: ?*const Config,
    comptime level: Level,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const c = config orelse return;
    const logger = c.logger orelse return;

    var buffer: [max_message_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // A truncated message is better than a dropped or overflowing one.
    writer.print(fmt, args) catch {};
    // The handler owns the line breaks: a format string that still ends with a
    // newline is trimmed here, so no handler has to strip one.
    const message = std.mem.trimEnd(u8, writer.buffered(), "\r\n");

    logger.logFn(logger.context, c, level, message);
}

const testing = std.testing;

const TestCapture = struct {
    calls: usize = 0,
    config: ?*const Config = null,
    level: ?Level = null,
    message: [max_message_len]u8 = undefined,
    message_len: usize = 0,
};

fn testLogFn(context: ?*anyopaque, config: ?*const Config, level: Level, message: []const u8) void {
    const capture: *TestCapture = @ptrCast(@alignCast(context.?));
    capture.calls += 1;
    capture.config = config;
    capture.level = level;
    capture.message_len = @min(message.len, capture.message.len);
    @memcpy(capture.message[0..capture.message_len], message[0..capture.message_len]);
}

test "default_logger - is a std.log logger and needs no configuration" {
    // `Logger{}` is valid without a `logFn`, which is what makes a config that
    // was not configured log instead of failing.
    const unconfigured: Logger = .{};
    try testing.expectEqual(defaultLogFn, unconfigured.logFn);
    try testing.expectEqual(@as(?*anyopaque, null), unconfigured.context);
    try testing.expectEqual(defaultLogFn, default_logger.logFn);
}

test "config - logs with default_logger unless it is set to null" {
    // not set at all: the default is `default_logger`
    const default_config: Config = .{};
    try testing.expectEqual(defaultLogFn, default_config.logger.?.logFn);

    // explicitly set to null: no logs
    const silent_config: Config = .{ .logger = null };
    try testing.expectEqual(silent, silent_config.logger);
    try testing.expectEqual(@as(?Logger, null), silent_config.logger);
}

test "log - a null logger emits nothing, not even through the default" {
    var capture: TestCapture = .{};
    var config: Config = .{ .logger = .{ .context = &capture, .logFn = testLogFn } };

    // a message without a config has no logger to honour
    log(null, .err, "dropped {d}", .{1});
    try testing.expectEqual(0, capture.calls);

    // `null` is "logging is off", not "use the default logger"
    config.logger = null;
    log(&config, .warn, "dropped as well", .{});
    try testing.expectEqual(0, capture.calls);
}

test "log - binds the message to the config" {
    var capture: TestCapture = .{};
    var config: Config = .{ .logger = .{ .context = &capture, .logFn = testLogFn } };

    log(&config, .warn, "hello {s}", .{"world"});

    try testing.expectEqual(1, capture.calls);
    try testing.expectEqual(&config, capture.config.?);
    try testing.expectEqual(Level.warn, capture.level.?);
    try testing.expectEqualStrings("hello world", capture.message[0..capture.message_len]);
}

test "log - trailing newlines are stripped from the message" {
    var capture: TestCapture = .{};
    var config: Config = .{ .logger = .{ .context = &capture, .logFn = testLogFn } };

    log(&config, .err, "boom\n", .{});

    try testing.expectEqualStrings("boom", capture.message[0..capture.message_len]);
}
