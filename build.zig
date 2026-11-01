const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "am",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addEnginePage(b, exe.root_module);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run am");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // The tests get their own module so that the throwaway keys below are wired into the tests only.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addEnginePage(b, test_module);
    addTestKeys(b, test_module);
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const tests = b.addTest(.{ .root_module = test_module, .filters = test_filters });
    const test_step = b.step("test", "Run unit tests (needs openssl on PATH), the engine page's and the token service's (node 24+, else skipped)");
    const run_tests = b.addRunArtifact(tests);
    // Cross-compiling (e.g. -Dtarget=x86_64-windows) still builds the tests, then skips running them.
    run_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_tests.step);

    // The engine page's own tests (JavaScript, against a fake MusicKit), run with node on the
    // host; skipped, with a note, where node 24+ isn't on PATH. A -Dtest-filter run is for Zig
    // tests by name, so it leaves them out.
    // The token service's tests (token-worker/) run the same way.
    if (test_filters.len == 0) {
        const runner = b.addExecutable(.{
            .name = "page-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/page_tests.zig"),
                .target = b.graph.host,
            }),
        });
        for ([_][]const u8{ "poc/web/app.test.mjs", "token-worker/test/worker.test.mjs" }) |file| {
            const node_tests = b.addRunArtifact(runner);
            node_tests.setName(b.fmt("node tests ({s})", .{file}));
            node_tests.addFileArg(b.path(file));
            // Where the tests note the one running, for the failure if node has to be stopped.
            _ = node_tests.addOutputFileArg("running.txt");
            // Run every time (the output file alone would cache it). With side effects, the default
            // stdio sends the output straight through in a terminal. Under the build system protocol
            // (`--listen=-`), which refuses inherited stdin and stdout, it drops stdout and shows
            // stderr for a failed step; the runner sends node's report there.
            node_tests.has_side_effects = true;
            test_step.dependOn(&node_tests.step);
        }
    }
}

/// The engine page stays in `poc/web` (JavaScript, since MusicKit JS runs in it) and is embedded
/// in the binary, so `am` runs without the repo. Embedded by these names.
fn addEnginePage(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("web/index.html", .{ .root_source_file = b.path("poc/web/index.html") });
    module.addAnonymousImport("web/app.js", .{ .root_source_file = b.path("poc/web/app.js") });
}

/// Generates throwaway keys with openssl, so no private key is ever committed and the parser is
/// checked against an independent implementation. The tests `@embedFile` them by these names.
fn addTestKeys(b: *std.Build, module: *std.Build.Module) void {
    const p256 = b.addSystemCommand(&.{ "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out" });
    const p256_pem = p256.addOutputFileArg2("p256.p8", .{});

    // SubjectPublicKeyInfo DER: the last 65 bytes are the uncompressed public point.
    const p256_pub = b.addSystemCommand(&.{ "openssl", "pkey", "-pubout", "-outform", "DER", "-in" });
    p256_pub.addFileArg(p256_pem);
    p256_pub.addArg("-out");
    const p256_pub_der = p256_pub.addOutputFileArg2("p256.pub.der", .{});

    // SEC1 ECPrivateKey with the optional [0] parameters, as Apple's keys carry them.
    const p256_sec1 = b.addSystemCommand(&.{ "openssl", "ec", "-param_enc", "named_curve", "-outform", "DER", "-in" });
    p256_sec1.addFileArg(p256_pem);
    p256_sec1.addArg("-out");
    const p256_sec1_der = p256_sec1.addOutputFileArg2("p256.sec1.der", .{});

    const p384 = b.addSystemCommand(&.{ "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384", "-out" });
    const p384_pem = p384.addOutputFileArg2("p384.p8", .{});

    const ed25519 = b.addSystemCommand(&.{ "openssl", "genpkey", "-algorithm", "ED25519", "-out" });
    const ed25519_pem = ed25519.addOutputFileArg2("ed25519.p8", .{});

    module.addAnonymousImport("testkey-p256.p8", .{ .root_source_file = p256_pem });
    module.addAnonymousImport("testkey-p256.pub.der", .{ .root_source_file = p256_pub_der });
    module.addAnonymousImport("testkey-p256.sec1.der", .{ .root_source_file = p256_sec1_der });
    module.addAnonymousImport("testkey-p384.p8", .{ .root_source_file = p384_pem });
    module.addAnonymousImport("testkey-ed25519.p8", .{ .root_source_file = ed25519_pem });
}
