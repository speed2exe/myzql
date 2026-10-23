//! Byte transport of a connection: a plain socket or a socket wrapped in TLS.
//!
//! Everything above the transport (the packet reader and writer) only depends
//! on `read` and `writeAll`, so the MySQL protocol code is unaware of whether
//! the connection is encrypted.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// Capacity of each buffer used by `std.crypto.tls.Client`: the size of the
/// largest possible TLS record.
const tls_buffer_len: usize = tls.Client.min_buffer_len;

/// Options for `Transport.startTls`.
pub const TlsOptions = struct {
    /// Host name or IP address literal of the server. Used for SNI and to check
    /// that the certificate was issued for this server. Only borrowed during
    /// `startTls`.
    host: []const u8,
    /// Verify that the certificate is signed by a trusted CA and that it was
    /// issued for `host`. Default: true.
    ///
    /// When false the connection is still encrypted, but the server is not
    /// authenticated, which makes the connection vulnerable to
    /// man-in-the-middle attacks.
    verify: bool = true,
    /// PEM file holding the CA certificates used to verify the server.
    /// Default: null, which uses the CA certificates installed on the system.
    /// Ignored when `verify` is false.
    ca_file: ?[]const u8 = null,
};

/// A connection to the server, either plain or encrypted with TLS.
pub const Transport = struct {
    allocator: Allocator,
    stream: Io.net.Stream,
    /// TLS state of the connection, set once the handshake has completed.
    tls: ?*Tls = null,

    /// TLS session of a connection.
    ///
    /// Heap allocated because `std.crypto.tls.Client` keeps pointers to the
    /// reader and writer it was initialized with, which must not move.
    const Tls = struct {
        client: tls.Client,
        stream_reader: Io.net.Stream.Reader,
        stream_writer: Io.net.Stream.Writer,
        /// Backing memory of the four buffers used by the TLS client, split
        /// into equally sized slices by `init`.
        buffers: []u8,
        /// CA certificates used to verify the server certificate, empty when
        /// verification is disabled.
        bundle: Certificate.Bundle,
        /// Required by `tls.Client.Options.ca.bundle`, even though a connection
        /// is only used by one thread at a time.
        bundle_lock: Io.RwLock,

        fn init(transport: *Transport, io: Io, options: TlsOptions) !*Tls {
            const allocator = transport.allocator;
            const state = try allocator.create(Tls);
            errdefer allocator.destroy(state);

            const buffers = try allocator.alloc(u8, tls_buffer_len * 4);
            errdefer allocator.free(buffers);

            state.* = .{
                .client = undefined,
                .stream_reader = undefined,
                .stream_writer = undefined,
                .buffers = buffers,
                .bundle = .empty,
                .bundle_lock = .init,
            };
            errdefer state.bundle.deinit(allocator);

            // encrypted bytes read from and written to the socket
            const socket_read_buffer = buffers[0..tls_buffer_len];
            const socket_write_buffer = buffers[tls_buffer_len..][0..tls_buffer_len];
            // decrypted bytes produced by and handed to the TLS client
            const read_buffer = buffers[tls_buffer_len * 2 ..][0..tls_buffer_len];
            const write_buffer = buffers[tls_buffer_len * 3 ..][0..tls_buffer_len];

            state.stream_reader = transport.stream.reader(io, socket_read_buffer);
            state.stream_writer = transport.stream.writer(io, socket_write_buffer);

            const now = Io.Timestamp.now(io, .real);
            if (options.verify) try state.loadCaBundle(allocator, io, now, options.ca_file);

            // `Options.entropy` is only read during `init`, it is not captured
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);

            state.client = tls.Client.init(
                &state.stream_reader.interface,
                &state.stream_writer.interface,
                .{
                    .host = if (options.verify) .{ .explicit = options.host } else .no_verification,
                    .ca = if (options.verify) .{ .bundle = .{
                        .gpa = allocator,
                        .io = io,
                        .lock = &state.bundle_lock,
                        .bundle = &state.bundle,
                    } } else .no_verification,
                    .read_buffer = read_buffer,
                    .write_buffer = write_buffer,
                    .entropy = &entropy,
                    .realtime_now = now,
                    // the MySQL protocol always knows how many bytes to expect,
                    // so a truncated stream is always a protocol error
                    .allow_truncation_attacks = false,
                },
            ) catch |err| switch (err) {
                // the detail is stored on the reader/writer the client uses
                error.ReadFailed => return state.stream_reader.err orelse error.TlsHandshakeFailed,
                error.WriteFailed => return state.stream_writer.err orelse error.TlsHandshakeFailed,
                else => |e| return e,
            };

            return state;
        }

        /// Fill `bundle` with the CA certificates the server is verified against.
        fn loadCaBundle(state: *Tls, allocator: Allocator, io: Io, now: Io.Timestamp, ca_file: ?[]const u8) !void {
            const path = ca_file orelse return state.bundle.rescan(allocator, io, now);
            if (std.fs.path.isAbsolute(path)) {
                return state.bundle.addCertsFromFilePathAbsolute(allocator, io, now, path);
            }
            return state.bundle.addCertsFromFilePath(allocator, io, now, Io.Dir.cwd(), path);
        }

        fn deinit(state: *Tls, allocator: Allocator) void {
            // A TLS stream which is closed without `close_notify` looks like a
            // truncation attack to the server. Errors are ignored on purpose,
            // the socket is about to be closed anyway.
            state.client.end() catch {};
            state.stream_writer.interface.flush() catch {};
            state.bundle.deinit(allocator);
            allocator.free(state.buffers);
        }

        fn read(state: *Tls, dest: []u8) !usize {
            // The TLS client decrypts into its own buffer, so at least one byte
            // has to be buffered before it can be copied out
            const buffered = state.client.reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return 0,
                error.ReadFailed => return state.client.read_err orelse error.ReadFailed,
            };
            const n = @min(buffered.len, dest.len);
            @memcpy(dest[0..n], buffered[0..n]);
            state.client.reader.toss(n);
            return n;
        }

        fn writeAll(state: *Tls, data: []const u8) !void {
            state.client.writer.writeAll(data) catch return state.writeFailed();
            state.client.writer.flush() catch return state.writeFailed();
            state.stream_writer.interface.flush() catch return state.writeFailed();
        }

        /// The TLS client reports every write failure as `error.WriteFailed`,
        /// the underlying error is stored on the socket writer.
        fn writeFailed(state: *const Tls) WriteError {
            return state.stream_writer.err orelse error.WriteFailed;
        }

        /// `error.WriteFailed` is added to the errors of the socket writer
        /// because the TLS client reports every failure that way.
        const WriteError = Io.net.Stream.Writer.Error || error{WriteFailed};
    };

    /// Create a plain transport over `stream`. Takes ownership of the stream.
    pub fn init(allocator: Allocator, stream: Io.net.Stream) Transport {
        return .{
            .allocator = allocator,
            .stream = stream,
        };
    }

    /// Send the TLS `close_notify` alert if the connection is encrypted, then
    /// close the socket and free all resources.
    pub fn close(t: *Transport, io: Io) void {
        if (t.tls) |state| {
            state.deinit(t.allocator);
            t.allocator.destroy(state);
            t.tls = null;
        }
        t.stream.close(io);
    }

    pub fn isTls(t: *const Transport) bool {
        return t.tls != null;
    }

    /// Perform the TLS handshake, encrypting the connection from now on.
    /// The server must already expect the handshake, i.e. the SSLRequest packet
    /// of the connection phase must have been sent.
    pub fn startTls(t: *Transport, io: Io, options: TlsOptions) !void {
        std.debug.assert(t.tls == null);
        t.tls = try Tls.init(t, io, options);
    }

    /// Read up to `dest.len` bytes from the connection into `dest`.
    /// Returns the number of bytes read, which is 0 when the peer closed the
    /// connection.
    pub fn read(t: *Transport, io: Io, dest: []u8) !usize {
        std.debug.assert(dest.len > 0);
        if (t.tls) |state| return state.read(dest);

        var bufs: [1][]u8 = .{dest};
        const result = try t.stream.readWithControl(io, &bufs, &.{});
        return result.data_len;
    }

    /// Write all of `data` to the connection.
    pub fn writeAll(t: *Transport, io: Io, data: []const u8) !void {
        if (t.tls) |state| return state.writeAll(data);

        var rest = data;
        while (rest.len > 0) {
            const result = try io.operate(.{ .net_write = .{
                .socket_handle = t.stream.socket.handle,
                .data = &.{rest},
            } });
            const n = try result.net_write;
            if (n == 0) return error.WriteZero;
            rest = rest[n..];
        }
    }
};
