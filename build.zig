const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    // const lib = b.addStaticLibrary("libsoundio", "src/main.zig");
    // lib.setBuildMode(mode);
    // link(lib);
    // lib.install();

    const main_tests = b.addTestExe("test", "src/main.zig");
    link(main_tests);
    main_tests.main_pkg_path = "src";
    main_tests.linkLibC();
    main_tests.setBuildMode(mode);
    main_tests.install();

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.run().step);
}

fn link(step: *std.build.LibExeObjStep) void {
    step.addLibraryPath("pulseaudio/build/src/pulse");
    step.linkSystemLibraryName("pulse");
}

fn buildPulseAudio() void {}
