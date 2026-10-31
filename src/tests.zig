test {
    _ = @import("main.zig");
    _ = @import("sandbox/sbpl.zig");
    _ = @import("sandbox/profile.zig");
    _ = @import("cli.zig");
    _ = @import("launch.zig");
    _ = @import("env/env.zig");
    _ = @import("macos.zig");
    _ = @import("secret.zig");
    _ = @import("broker/server.zig");
    _ = @import("gateway.zig");
    _ = @import("broker/rpc.zig");
    _ = @import("client.zig");
    _ = @import("broker/registry.zig");
    _ = @import("broker/command.zig");
    _ = @import("env/store.zig");
    _ = @import("env/manifest.zig");
    _ = @import("env/sandbox_env.zig");
    _ = @import("log.zig");
}
