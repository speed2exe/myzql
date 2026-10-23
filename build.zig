const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const myzql = b.addModule("myzql", .{
        .root_source_file = b.path("./src/myzql.zig"),
    });

    // -Dtest-filter="..."
    const test_filter = b.option([]const []const u8, "test-filter", "Filter for tests to run");

    // zig build unit_test
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/myzql.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (test_filter) |t| unit_tests.filters = t;

    // zig build [install]
    b.installArtifact(unit_tests);

    // zig build -Dtest-filter="..." run_unit_test
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("unit_test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // -Dunix-socket-path="/path/to/mysqld.sock"
    const unix_socket_path = b.option([]const u8, "unix-socket-path", "Path to MySQL Unix domain socket for integration tests");
    // -Dskip-stress=true (skip 16M-row stress test, useful for CI)
    const skip_stress = b.option(bool, "skip-stress", "Skip the stress test (heavy, 16M rows)") orelse false;
    // -Dtls-ca-path="/path/to/ca.pem" (CA certificate of the TLS test server)
    const tls_ca_path = b.option([]const u8, "tls-ca-path", "Path to the CA certificate (PEM) that signed the certificate of the TLS test server");
    // -Dtls-wrong-host-port=3308 (TLS server with a certificate for another host)
    const tls_wrong_host_port = b.option(u16, "tls-wrong-host-port", "Port of a TLS MySQL server whose certificate is not valid for 127.0.0.1");
    // -Dnotls-port=3307 (MySQL/MariaDB server without TLS support)
    const notls_port = b.option(u16, "notls-port", "Port of a MySQL server without TLS support");
    const integration_test_opts = b.addOptions();
    integration_test_opts.addOption(?[]const u8, "unix_socket_path", unix_socket_path);
    integration_test_opts.addOption(bool, "skip_stress", skip_stress);
    integration_test_opts.addOption(?[]const u8, "tls_ca_path", tls_ca_path);
    integration_test_opts.addOption(?u16, "tls_wrong_host_port", tls_wrong_host_port);
    integration_test_opts.addOption(?u16, "notls_port", notls_port);

    // zig build -Dtest-filter="..." integration_test
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .link_libc = true,
            .root_source_file = b.path("./integration_tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("myzql", myzql);
    integration_tests.root_module.addOptions("build_options", integration_test_opts);
    if (test_filter) |t| integration_tests.filters = t;

    // zig build [install]
    b.installArtifact(integration_tests);

    // zig build integration_test
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration_test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
