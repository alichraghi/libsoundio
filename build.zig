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
    step.addCSourceFile("src/pipewire/builder.c", &.{"-D_REENTRANT"});
    step.defineCMacro("_REENTRANT", null);

    step.addIncludePath("/usr/include/spa-0.2");
    step.addIncludePath("/usr/include/pipewire-0.3");
    step.linkSystemLibraryName("pipewire-0.3");
    step.linkSystemLibraryName("pulse");
    step.linkSystemLibraryName("jack");
}

fn buildPulseAudio() void {}
