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

    const run_step = b.step("run", "Run the app");
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArg("ent.w3g");
    run_step.dependOn(&run_cmd.step);
}
