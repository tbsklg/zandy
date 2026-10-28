const std = @import("std");
const store = @import("store.zig");
const manifest_mod = @import("manifest.zig");

const SandboxEnv = @This();

root: store.StorePath,
bin: []const u8,
closure: []const store.StorePath,
manifest: manifest_mod.Manifest,

pub fn parse(arena: std.mem.Allocator, root: store.StorePath, store_paths: []const u8, manifest_json: []const u8) !SandboxEnv {
    const closure = try std.mem.concat(arena, store.StorePath, &.{ &.{root}, try store.parseStorePaths(arena, store_paths) });
    const manifest = try manifest_mod.parse(arena, manifest_json);

    for (manifest.adapters) |adapter| {
        if (try inClosure(closure, adapter.binary)) return error.AdapterInSandbox;
    }
    for (manifest.gateways) |gateway| switch (gateway.auth) {
        .header => {},
        .proxy => |proxy| {
            if (proxy.argv.len == 0) return error.EmptyProxyArgv;
            if (try inClosure(closure, proxy.argv[0])) return error.GatewayInSandbox;
        },
    };

    return .{
        .root = root,
        .bin = try std.fs.path.join(arena, &.{ root.path, "sandbox", "bin" }),
        .closure = closure,
        .manifest = manifest,
    };
}

fn inClosure(closure: []const store.StorePath, binary: []const u8) !bool {
    const binary_path = try store.owner(binary);
    for (closure) |p| {
        if (std.mem.eql(u8, p.path, binary_path.path)) return true;
    }
    return false;
}

pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) !SandboxEnv {
    const root = try store.parse(try std.Io.Dir.cwd().realPathFileAlloc(io, path, arena));
    const dir = std.Io.Dir.cwd();
    const store_paths = try dir.readFileAlloc(io, try std.fs.path.join(arena, &.{ root.path, "store-paths" }), arena, .limited(16 * 1024 * 1024));
    const manifest_json = try dir.readFileAlloc(io, try std.fs.path.join(arena, &.{ root.path, "zandy.json" }), arena, .limited(16 * 1024 * 1024));
    return parse(arena, root, store_paths, manifest_json);
}

const test_root = "/nix/store/z946f4g3p26f9ldiw615frpcizy31aq4-demo";
const test_paths =
    \\/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0
    \\/nix/store/7f0sryhgq9arkgzmv2pfzyxn40p7j69f-glab-1.0
    \\
;

fn testManifest(comptime binary: []const u8) []const u8 {
    return
    \\{"preset":{"name":"claude","binary":"claude","profile":{}},
    \\ "adapters":[{"name":"gitlab","binary":"
    ++ binary ++
        \\","capabilities":[]}]}
    ;
}

test "the closure includes the env itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const env = try parse(arena_state.allocator(), try store.parse(test_root), test_paths, testManifest("/nix/store/n9925m4950mn5i2bmlh50lds2ih6yg1v-glab-1.0/bin/glab"));

    try std.testing.expectEqualStrings(test_root, env.closure[0].path);
    try std.testing.expectEqual(3, env.closure.len);
    try std.testing.expectEqualStrings(test_root ++ "/sandbox/bin", env.bin);
}

test "rejects an adapter whose binary can be executed in the sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.AdapterInSandbox, parse(arena_state.allocator(), try store.parse(test_root), test_paths, testManifest("/nix/store/7f0sryhgq9arkgzmv2pfzyxn40p7j69f-glab-1.0/bin/glab")));
}

test "rejects an adapter binary outside the store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidStorePath, parse(arena_state.allocator(), try store.parse(test_root), test_paths, testManifest("/opt/homebrew/bin/glab")));
}

fn gatewayManifest(comptime argv: []const u8) []const u8 {
    return
    \\{"preset":{"name":"claude","binary":"claude","profile":{}},
    \\ "gateways":[{"name":"bedrock","upstream":"https://bedrock-runtime.eu-west-1.amazonaws.com",
    \\   "auth":{"proxy":{"argv":[
    ++ argv ++
        \\]}}}]}
    ;
}

test "rejects a gateway whose proxy can be executed in the sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.GatewayInSandbox, parse(arena_state.allocator(), try store.parse(test_root), test_paths, gatewayManifest("\"/nix/store/lw5h7x6kxqdx6m8wnsqjjzj6fd1i9x2j-ripgrep-15.2.0/bin/aws-sigv4-proxy\"")));
}

test "rejects a gateway proxy outside the store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidStorePath, parse(arena_state.allocator(), try store.parse(test_root), test_paths, gatewayManifest("\"/opt/homebrew/bin/aws-sigv4-proxy\"")));
}

test "rejects a gateway proxy without argv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.EmptyProxyArgv, parse(arena_state.allocator(), try store.parse(test_root), test_paths, gatewayManifest("")));
}

test "accepts a gateway whose proxy stays outside the sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const env = try parse(arena_state.allocator(), try store.parse(test_root), test_paths, gatewayManifest("\"/nix/store/bz0ghsayh5s01kb5dzfvjg2gprm3mzgs-aws-sigv4-proxy-1.13/bin/aws-sigv4-proxy\""));
    try std.testing.expectEqualStrings("bedrock", env.manifest.gateways[0].name);
}
