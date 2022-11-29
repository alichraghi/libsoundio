const std = @import("std");

pub const pkg = std.build.Pkg{
    .name = "sysaudio",
    .source = .{ .path = "src/main.zig" },
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const sine_wave = b.addExecutable("sine_wave", "example/sine_wave.zig");
    sine_wave.addPackage(pkg);
    sine_wave.setTarget(target);
    sine_wave.setBuildMode(mode);
    link(sine_wave);
    sine_wave.install();

    const main_tests = b.addTest("src/util.zig");
    link(main_tests);
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);

    const sine_wave_step = b.step("sine_wave", "Run library tests");
    sine_wave_step.dependOn(&sine_wave.step);
    // test_step.dependOn(&main_tests.step);
}

fn link(step: *std.build.LibExeObjStep) void {
    step.linkLibC();
    if (step.target_info.target.os.tag != .windows) {
        step.linkSystemLibrary("pulse");
        step.linkSystemLibrary("asound");
    }
}

fn buildPulseAudio() void {}
