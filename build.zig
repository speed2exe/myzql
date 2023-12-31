const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    _ = b.addModule("myzql", .{
        .source_file = .{ .path = "./src/myzql.zig" },
    });

    // zig build unit_test
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "./src/myzql.zig" },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("unit_test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // zig build integration_test
    // run test: error: unable to spawn .../myzql/zig-cache/o/10ad607cabdbbbddf584ad4ba72fa8d7/test: BrokenPipe
    const integration_tests = b.addTest(.{
        .root_source_file = .{ .path = "./integration_tests/main.zig" },
        .main_mod_path = .{ .path = "./" },
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration_test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
