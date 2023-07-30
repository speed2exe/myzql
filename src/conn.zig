const std = @import("std");
const mysql_const = @import("./mysql_const.zig");
const Config = @import("./config.zig").Config;

const maxPacketSize = 1 << 24 - 1;

const Conn = struct {
    const buffer_size = 4096;
    const Buffer = std.io.BufferedReader(buffer_size, std.net.Stream);
    const State = union(enum) {
        Disconnected,
        Connected: struct {
            stream: std.net.Stream,
            buffer: Buffer,
        },
    };

    host: []const u8,
    port: u16,
    config: Config,
    state: State = .Disconnected,
    sequence: u8 = 0, // TODO: Not sure what this does, check
    flags: u32 = 0, // TODO: Not sure what this does, check

    pub fn init(host: []const u8, port: u16, config: Config) Conn {
        return .{
            .host = host,
            .port = port,
            .config = config,
        };
    }

    pub fn close(conn: Conn) void {
        switch (conn.State) {
            .Connected => {
                conn.state.Connected.stream.close();
                conn.state = .Disconnected;
            },
            .Disconnected => {},
        }
    }

    pub fn ping(conn: Conn) !void {
        try conn.connectIfDisconnected(conn.host, conn.port);
    }

    fn connectIfDisconnected(conn: Conn) !void {
        switch (conn.state) {
            .Connected => {},
            .Disconnected => try conn.connect(),
        }
    }

    fn connect(conn: Conn, allocator: std.mem.Allocator) !void {
        // dial
        var stream = try std.net.tcpConnectToHost(conn.allocator, conn.host, conn.port);
        const buffer = std.io.bufferedReader(stream.reader());
        conn.state = .Connected{ .stream = stream, .buffer = buffer };
        errdefer conn.close();

        const packet = try conn.readPacket(allocator);
        defer conn.allocator.free(packet);

        if (packet[0] == mysql_const.i_err) {
            return conn.handleErrorPacket(packet);
        }
        if (packet[0] < mysql_const.min_protocol_version) {
            std.log.err(
                "unsupported protocol version: {d}, expected at least {d}\n",
                .{ packet[0], mysql_const.min_protocol_version },
            );
            return error.UnsupportedProtocolVersion;
        }

        // Server version: Null-terminated string
        var pos = std.mem.indexOfScalarPos(u8, packet, 1, 0);
        const server_version = packet[1 .. pos - 1];
        std.log.info("server version: {s}\n", .{server_version});

        // Connection id: 4 bytes
        const connection_id = std.mem.readIntSliceLittle(u32, packet[pos .. pos + 4]);
        std.log.info("connection id: {d}\n", .{connection_id});
        pos += 4 + 1; // +1 for filler

        // Auth plugin data part 1: 8 bytes
        const auth_data1: *[8]u8 = packet[pos .. pos + 8];
        pos += 8 + 1; // +1 for filler
        std.log.info("auth data: {x}\n", .{auth_data1});

        // Capabilities: 2 bytes
        conn.flags = std.mem.readIntSliceLittle(u16, packet[pos .. pos + 2]);
        pos += 2;
        if (conn.flags & mysql_const.client_protocol_41 == 0) {
            std.log.err("MySQL server does not support required protocol 41+");
            return error.OldProtocol;
        }
        if (conn.flags & mysql_const.client_ssl == 0 and conn.config.tls) { // TODO: support TLS
            if (conn.config.allow_fallback_to_plaintext) {
                conn.config.tls = false;
            } else {
                std.log.err("MySQL server does not support SSL");
                return error.SSLUnsupported;
            }
        }

        var auth_plugin: []u8 = undefined;
        var auth_data2: ?*[12]u8 = null;
        if (packet.len > pos) {
            // character set [1 byte]
            // status flags [2 bytes]
            // capability flags (upper 2 bytes) [2 bytes]
            // length of auth-plugin-data [1 byte]
            // reserved (all [00]) [10 bytes]
            pos += 1 + 2 + 2 + 1 + 10;

            // second part of the password cipher [mininum 13 bytes],
            // where len=MAX(13, length of auth-plugin-data - 8)
            //
            // The web documentation is ambiguous about the length. However,
            // according to mysql-5.7/sql/auth/sql_authentication.cc line 538,
            // the 13th byte is "\0 byte, terminating the second part of
            // a scramble". So the second part of the password cipher is
            // a NULL terminated string that's at least 13 bytes with the
            // last byte being NULL.
            //
            // The official Python library uses the fixed length 12
            // which seems to work but technically could have a hidden bug.
            auth_data2 = packet[pos .. pos + 12];
            pos += 12 + 1; // +1 for filler

            if (std.mem.indexOfScalarPos(u8, packet, pos, 0)) |end| {
                auth_plugin = packet[pos..end];
            } else {
                auth_plugin = packet[pos..];
            }
        } else {
            auth_plugin = mysql_const.default_auth_plugin;
        }

        const auth_data: []u8 = blk: {
            var full: [20]u8 = undefined;
            @memcpy(&full, auth_data1);
            if (auth_data2) {
                @memcpy(full[8..], auth_data2);
                break :blk &full;
            } else {
                break :blk full[0..8];
            }
        };

        try conn.auth(auth_data, auth_plugin);
    }

    fn auth(conn: Conn, auth_data: []u8, auth_plugin: []const u8) !void {
        if (std.mem.eql(u8, auth_plugin, "caching_sha2_password")) {
            scrambleSHA256Password(auth_data, conn.config.password);
            // 	return authResp, nil
        }

        // case "mysql_old_password":
        // 	if !mc.cfg.AllowOldPasswords {
        // 		return nil, ErrOldPassword
        // 	}
        // 	if len(mc.cfg.Passwd) == 0 {
        // 		return nil, nil
        // 	}
        // 	// Note: there are edge cases where this should work but doesn't;
        // 	// this is currently "wontfix":
        // 	// https://github.com/go-sql-driver/mysql/issues/184
        // 	authResp := append(scrambleOldPassword(authData[:8], mc.cfg.Passwd), 0)
        // 	return authResp, nil

        // case "mysql_clear_password":
        // 	if !mc.cfg.AllowCleartextPasswords {
        // 		return nil, ErrCleartextPassword
        // 	}
        // 	// http://dev.mysql.com/doc/refman/5.7/en/cleartext-authentication-plugin.html
        // 	// http://dev.mysql.com/doc/refman/5.7/en/pam-authentication-plugin.html
        // 	return append([]byte(mc.cfg.Passwd), 0), nil

        // case "mysql_native_password":
        // 	if !mc.cfg.AllowNativePasswords {
        // 		return nil, ErrNativePassword
        // 	}
        // 	// https://dev.mysql.com/doc/internals/en/secure-password-authentication.html
        // 	// Native password authentication only need and will need 20-byte challenge.
        // 	authResp := scramblePassword(authData[:20], mc.cfg.Passwd)
        // 	return authResp, nil

        // case "sha256_password":
        // 	if len(mc.cfg.Passwd) == 0 {
        // 		return []byte{0}, nil
        // 	}
        // 	// unlike caching_sha2_password, sha256_password does not accept
        // 	// cleartext password on unix transport.
        // 	if mc.cfg.TLS != nil {
        // 		// write cleartext auth packet
        // 		return append([]byte(mc.cfg.Passwd), 0), nil
        // 	}

        // 	pubKey := mc.cfg.pubKey
        // 	if pubKey == nil {
        // 		// request public key from server
        // 		return []byte{1}, nil
        // 	}

        // 	// encrypted password
        // 	enc, err := encryptPassword(mc.cfg.Passwd, authData, pubKey)
        // 	return enc, err

        // default:
        // 	mc.cfg.Logger.Print("unknown auth plugin:", plugin)
        // 	return nil, ErrUnknownPlugin
    }

    // TODO: test
    // XOR(SHA256(password), SHA256(SHA256(SHA256(password)), scramble))

    fn readPacket(conn: Conn, allocator: std.mem.Allocator) ![]u8 {
        errdefer conn.close();

        var accumulator = std.ArrayList(u8).init(allocator);
        errdefer accumulator.deinit();

        const reader = conn.state.Connected.buffer.reader();

        while (true) {
            const header = try reader.readBytesNoEof(4);
            const pkt_len = header[0] | header[1] << 8 | header[2] << 16;

            if (header[3] != conn.sequence) {
                if (header[3] > conn.sequence) {
                    std.log.err("commands out of sync. Did you run multiple statements at once?\n");
                    return error.PacketSyncMulti;
                }
                std.log.err("commands out of sync. You can't run this command now\n");
                return error.PacketSync;
            }
            conn.sequence += 1;

            if (pkt_len == 0) {
                if (accumulator.items.len == 0) {
                    return error.InvalidConnection;
                }
                return accumulator.toOwnedSlice();
            }

            var data = try accumulator.addManyAsSlice(pkt_len);
            try reader.readAll(data);
        }
    }

    fn handleErrorPacket(conn: Conn, packet: []const u8) !void {
        if (packet[0] != mysql_const.i_err) {
            std.log.err("expected error packet, got %x\n", .{packet[0]});
            return error.MalformedPacket;
        }

        const err_number = std.mem.readIntSliceLittle(u16, packet[1..3]);
        std.log.err("error number: %d\n", .{err_number});

        // 1792: ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION
        // 1290: ER_OPTION_PREVENTS_STATEMENT (returned by Aurora during failover)
        if ((err_number == 1792 or err_number == 1290) and conn.config.reject_read_only) {
            // Oops; we are connected to a read-only connection, and won't be able
            // to issue any write statements. Since RejectReadOnly is configured,
            // we throw away this connection hoping this one would have write
            // permission. This is specifically for a possible race condition
            // during failover (e.g. on AWS Aurora). See README.md for more.
            //
            // We explicitly close the connection before returning
            // driver.ErrBadConn to ensure that `database/sql` purges this
            // connection and initiates a new one for next statement next time.
            conn.close();
            std.log.err("rejecting read-only connection\n");
            return error.DriverBadConnection;
        }

        // SQL State [optional: # + 5bytes string]
        if (packet[3] == 0x23) {
            std.log.err("sql state: {d}\n", .{packet[4..9]});
            std.log.err("error message: {s}\n", .{packet[9..]});
        } else {
            std.log.err("error message: {s}\n", .{packet[3..]});
        }
    }
};

fn scrambleSHA256Password(scramble: []const u8, password: []const u8) [32]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;

    var message1 = blk: {
        var hasher = Sha256.init(.{});
        hasher.update(password);
        break :blk hasher.finalResult();
    };
    const message2 = blk: {
        var hasher = Sha256.init(.{});
        hasher.update(&message1);
        var temp = hasher.finalResult();

        hasher = Sha256.init(.{});
        hasher.update(&temp);
        hasher.update(scramble);
        hasher.final(&temp);
        break :blk temp;
    };
    for (&message1, message2) |*m1, m2| {
        m1.* ^= m2;
    }
    return message1;
}

test "scrambleSHA256Password" {
    const scramble = [_]u8{ 10, 47, 74, 111, 75, 73, 34, 48, 88, 76, 114, 74, 37, 13, 3, 80, 82, 2, 23, 21 };
    const tests = [_]struct {
        password: []const u8,
        expected: [32]u8,
    }{
        .{
            .password = "secret",
            .expected = .{ 244, 144, 231, 111, 102, 217, 216, 102, 101, 206, 84, 217, 140, 120, 208, 172, 254, 47, 176, 176, 139, 66, 61, 168, 7, 20, 72, 115, 211, 11, 49, 44 },
        },
        .{
            .password = "secret2",
            .expected = .{ 171, 195, 147, 74, 1, 44, 243, 66, 232, 118, 7, 28, 142, 226, 2, 222, 81, 120, 91, 67, 2, 88, 167, 160, 19, 139, 199, 156, 77, 128, 11, 198 },
        },
    };

    for (tests) |t| {
        const actual = scrambleSHA256Password(&scramble, t.password);
        try std.testing.expectEqual(t.expected, actual);
    }
}
