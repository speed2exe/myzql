const std = @import("std");

pub fn build(b: *std.Build) void {
    const myzql = b.addModule("myzql", .{
        .root_source_file = .{ .path = "./src/myzql.zig" },
    });

    // zig build unit_test
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "./src/myzql.zig" },
    });

    // zig build [install]
    b.installArtifact(unit_tests);

    // zig build run_unit_test
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("unit_test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // zig build integration_test
    // integration_test
    // └─ run test failure
    // error: unable to spawn /<some-path>/myzql/zig-cache/o/82ac61612eaa882f2401e0d249b59437/test: BrokenPipe
    //
    // Use this command for now:
    // zig test --dep myzql --mod root ./integration_tests/main.zig --mod myzql ./src/myzql.zig --name test
    const integration_tests = b.addTest(.{
        .root_source_file = .{ .path = "./integration_tests/main.zig" },
    });
    integration_tests.root_module.addImport("myzql", myzql);

    // zig build [install]
    b.installArtifact(integration_tests);

    // zig build run_integration_test
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration_test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
