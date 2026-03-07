const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library module
    const volt_core_mod = b.addModule("volt-core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable (CLI + TUI)
    const exe = b.addExecutable(.{
        .name = "volt",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("volt-core", volt_core_mod);
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run Volt");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const core_tests = b.addTest(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_main_tests = b.addRunArtifact(main_tests);

    // Integration tests
    const chain_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_chain_propagation.zig"),
        .target = target,
        .optimize = optimize,
    });
    chain_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_chain_tests = b.addRunArtifact(chain_tests);

    // Large Postman collection import test (100+ requests)
    const large_postman_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_large_postman_import.zig"),
        .target = target,
        .optimize = optimize,
    });
    large_postman_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_large_postman_tests = b.addRunArtifact(large_postman_tests);

    // Large response performance test (50MB JSON)
    const large_response_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_large_response.zig"),
        .target = target,
        .optimize = optimize,
    });
    large_response_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_large_response_tests = b.addRunArtifact(large_response_tests);

    // Protocol fixture parser validation tests
    const protocol_fixture_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_protocol_fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_fixture_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_protocol_fixture_tests = b.addRunArtifact(protocol_fixture_tests);

    // Integration test harness (roundtrip, export pipeline, variable resolution)
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // OpenAPI import validation tests
    const openapi_import_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_openapi_import.zig"),
        .target = target,
        .optimize = optimize,
    });
    openapi_import_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_openapi_import_tests = b.addRunArtifact(openapi_import_tests);

    // Export code generation tests (curl, python, javascript, go)
    const export_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_export.zig"),
        .target = target,
        .optimize = optimize,
    });
    export_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_export_tests = b.addRunArtifact(export_tests);

    // Search, tree, stats, and sorting tests
    const search_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_search.zig"),
        .target = target,
        .optimize = optimize,
    });
    search_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_search_tests = b.addRunArtifact(search_tests);

    // Lint and validation tests (schema validation, formatting)
    const lint_validate_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_lint_validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    lint_validate_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_lint_validate_tests = b.addRunArtifact(lint_validate_tests);

    // Replay and history tests (response diffing, cookie jar)
    const replay_history_tests = b.addTest(.{
        .root_source_file = b.path("tests/launch-schedule/test_replay_history.zig"),
        .target = target,
        .optimize = optimize,
    });
    replay_history_tests.root_module.addImport("volt-core", volt_core_mod);
    const run_replay_history_tests = b.addRunArtifact(replay_history_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_chain_tests.step);
    test_step.dependOn(&run_large_postman_tests.step);
    test_step.dependOn(&run_large_response_tests.step);
    test_step.dependOn(&run_protocol_fixture_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_openapi_import_tests.step);
    test_step.dependOn(&run_export_tests.step);
    test_step.dependOn(&run_search_tests.step);
    test_step.dependOn(&run_lint_validate_tests.step);
    test_step.dependOn(&run_replay_history_tests.step);

    // Separate step for integration tests only
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_chain_tests.step);
    integration_test_step.dependOn(&run_large_postman_tests.step);
    integration_test_step.dependOn(&run_large_response_tests.step);
    integration_test_step.dependOn(&run_protocol_fixture_tests.step);
    integration_test_step.dependOn(&run_integration_tests.step);
    integration_test_step.dependOn(&run_openapi_import_tests.step);
    integration_test_step.dependOn(&run_export_tests.step);
    integration_test_step.dependOn(&run_search_tests.step);
    integration_test_step.dependOn(&run_lint_validate_tests.step);
    integration_test_step.dependOn(&run_replay_history_tests.step);
}
