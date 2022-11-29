const c = @cImport(@cInclude("audioclient.h"));

comptime {
    _ = c;
}
