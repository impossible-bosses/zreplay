const std = @import("std");

const zlib = @import("deps/zlib/build.zig");

pub fn build(b: *std.build.Builder) void
{
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zreplay", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludeDir("deps/zlib");
    zlib.addLib(exe, "deps/zlib");
    exe.linkLibC();
    exe.install();

    const runStep = b.step("run", "Run the app");
    const runCmd = exe.run();
    runCmd.step.dependOn(b.getInstallStep());
    runCmd.addArg("ent.w3g");
    runStep.dependOn(&runCmd.step);

    const testBuildStep = b.addTest("src/main.zig");
    testBuildStep.setBuildMode(mode);
    const testStep = b.step("test", "Run library tests");
    testStep.dependOn(&testBuildStep.step);
}
