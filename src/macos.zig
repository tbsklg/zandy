/// /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sandbox.h
pub extern "c" fn sandbox_init(profile: [*c]const u8, flags: u64, errorbuf: [*c][*c]u8) c_int;

/// https://chromium.googlesource.com/chromium/src/+/main/sandbox/mac/seatbelt.cc
pub extern "c" fn sandbox_init_with_parameters(
    profile: [*:0]const u8,
    flags: u64,
    parameters: [*:null]const ?[*:0]const u8,
    errorbuf: *?[*:0]u8,
) c_int;

/// /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sandbox.h
pub extern fn sandbox_free_error(errorbuf: [*c]u8) void;
