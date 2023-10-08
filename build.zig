const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    _ = target;

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;

    _ = b.addModule("myzql", .{
        .source_file = .{ .path = "src/myzql.zig" },
    });

    // Issue with `zig build test`:
    // run test: error: unable to spawn /???/myzql/zig-cache/o/921007debaa2f10851a996ef85aebfaf/test: BrokenPipe
    // Build Summary: 1/3 steps succeeded; 1 failed (disable with --summary none)
    // test transitive failure
    // └─ run test failure
    // error: the following build command failed with exit code 1:
    // /home/zx/github.com/speed2exe/myzql/zig-cache/o/f87ecf36506c9f93831ae5aec3f4b195/build /usr/bin/zig /home/zx/github.com/speed2exe/myzql /home/zx/github.com/speed2exe/myzql/zig-cache /home/zx/.cache/zig test
    //
    // // Creates a step for unit testing. This only builds the test executable
    // // but does not run it.
    // const tests = b.addTest(.{
    //     .root_source_file = .{ .path = "src/myzql.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const run_tests = b.addRunArtifact(tests);

    // // This creates a build step. It will be visible in the `zig build --help` menu,
    // // and can be selected like this: `zig build test`
    // // This will evaluate the `test` step rather than the default, which is "install".
    // const test_step = b.step("test", "Run library tests");
    // test_step.dependOn(&run_tests.step);
}
