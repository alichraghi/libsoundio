const std = @import("std");

pub const pkg = std.build.Pkg{
    .name = "soundio",
    .source = .{ .path = "src/main.zig" },
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const behavior_tests = b.addTestExe("test", "test/main.zig");
    link(behavior_tests);
    behavior_tests.addPackage(pkg);
    behavior_tests.setTarget(target);
    behavior_tests.setBuildMode(mode);
    behavior_tests.install();

    const main_tests = b.addTest("src/util.zig");
    link(main_tests);
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&behavior_tests.run().step);
    test_step.dependOn(&main_tests.step);
}

fn link(step: *std.build.LibExeObjStep) void {
    step.linkLibC();
    step.addIncludePath("alsa-lib/include");
    step.addLibraryPath("/home/ali/dev/libsoundio/alsa-lib/src/.libs");
    step.linkSystemLibrary("pulse");
    step.linkSystemLibrary("asound");
    step.linkSystemLibrary("jack");
}

fn buildPulseAudio() void {}
