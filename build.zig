const std = @import("std");

pub const pkg = std.build.Pkg{
    .name = "soundio",
    .source = .{ .path = "src/main.zig" },
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const main_tests = b.addTestExe("test", "test/main.zig");
    link(main_tests);
    main_tests.addPackage(pkg);
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);
    main_tests.install();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.run().step);
}

fn link(step: *std.build.LibExeObjStep) void {
    step.linkLibC();
    step.addIncludePath("/usr/include");
    step.addIncludePath("alsa-lib/include");
    step.addLibraryPath("/home/ali/dev/libsoundio/alsa-lib/src/.libs");
    step.linkSystemLibrary("pulse");
    step.linkSystemLibrary("asound");
    step.linkSystemLibrary("jack");
}

fn buildPulseAudio() void {}
