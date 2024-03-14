const std = @import("std");

pub fn build(b: *std.Build) void {
    const myzql = b.addModule("myzql", .{
        .root_source_file = .{ .path = "./src/myzql.zig" },
    });

    // -Dtest-filter="..."
    const test_filter = b.option([]const u8, "test-filter", "Filter for tests to run");

    // zig build unit_test
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "./src/myzql.zig" },
    });
    if (test_filter) |t| unit_tests.filters = &.{t};

    // zig build [install]
    b.installArtifact(unit_tests);

    // zig build run_unit_test -Dtest-filter="..."
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("unit_test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // zig build integration_test -Dtest-filter="..."
    const integration_tests = b.addTest(.{
        .root_source_file = .{ .path = "./integration_tests/main.zig" },
    });
    integration_tests.root_module.addImport("myzql", myzql);
    if (test_filter) |t| unit_tests.filters = &.{t};

    // zig build [install]
    b.installArtifact(integration_tests);

    // zig build integration_test
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration_test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
