const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Shell Completion Generator ──────────────────────────────────────────
// Generates completion scripts for bash, zsh, fish, and PowerShell.
// Provides tab-completion for all Volt CLI commands and their arguments.

pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,

    pub fn fromString(s: []const u8) ?Shell {
        if (mem.eql(u8, s, "bash")) return .bash;
        if (mem.eql(u8, s, "zsh")) return .zsh;
        if (mem.eql(u8, s, "fish")) return .fish;
        if (mem.eql(u8, s, "powershell")) return .powershell;
        return null;
    }

    pub fn toString(self: Shell) []const u8 {
        return switch (self) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .powershell => "powershell",
        };
    }
};

const commands = [_][]const u8{
    "run",        "test",      "bench",     "mock",       "export",
    "collection", "graphql",   "generate",  "init",       "import",
    "env",        "history",   "lint",      "diff",       "version",
    "help",       "workflow",  "validate",  "docs",       "completions",
    "monitor",    "cache",     "ws",        "sse",        "auth",
};

const command_descriptions = [_][]const u8{
    "Execute a .volt request file",
    "Run test assertions against a request",
    "Benchmark a request with repeated runs",
    "Start a mock server from .volt files",
    "Export requests to other formats",
    "Manage request collections",
    "Execute GraphQL queries",
    "Generate test assertions from responses",
    "Initialize a new Volt project",
    "Import from Postman, Insomnia, or cURL",
    "Manage environment variables",
    "Show request history",
    "Lint .volt files for errors",
    "Diff two .volt files or responses",
    "Show Volt version information",
    "Show help information",
    "Run multi-step workflows",
    "Validate .volt file syntax",
    "Generate API documentation",
    "Generate shell completion scripts",
    "Monitor endpoint health",
    "Manage request/response cache",
    "WebSocket client",
    "Server-Sent Events client",
    "Manage authentication credentials",
};

const file_commands = [_][]const u8{
    "run", "test", "bench", "export", "lint", "validate", "diff", "docs",
};

const export_formats = [_][]const u8{
    "curl",       "python",     "javascript", "go",     "openapi",
    "ruby",       "php",        "csharp",     "rust",   "java",
    "swift",      "kotlin",     "dart",       "har",
};

/// Generate completion script for the specified shell
pub fn generateCompletions(allocator: Allocator, shell: Shell) ![]const u8 {
    return switch (shell) {
        .bash => generateBashCompletions(allocator),
        .zsh => generateZshCompletions(allocator),
        .fish => generateFishCompletions(allocator),
        .powershell => generatePowerShellCompletions(allocator),
    };
}

/// Generate bash completion script
pub fn generateBashCompletions(allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("# Bash completion for Volt API Client\n");
    try writer.writeAll("# Add to ~/.bashrc: eval \"$(volt completions bash)\"\n\n");

    try writer.writeAll("_volt() {\n");
    try writer.writeAll("    local cur prev commands\n");
    try writer.writeAll("    COMPREPLY=()\n");
    try writer.writeAll("    cur=\"${COMP_WORDS[COMP_CWORD]}\"\n");
    try writer.writeAll("    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n\n");

    // Build commands string
    try writer.writeAll("    commands=\"");
    for (commands, 0..) |cmd, i| {
        if (i > 0) try writer.writeAll(" ");
        try writer.writeAll(cmd);
    }
    try writer.writeAll("\"\n\n");

    // Subcommand completions
    try writer.writeAll("    case \"${prev}\" in\n");

    // export format completion
    try writer.writeAll("        export)\n");
    try writer.writeAll("            local formats=\"");
    for (export_formats, 0..) |fmt, i| {
        if (i > 0) try writer.writeAll(" ");
        try writer.writeAll(fmt);
    }
    try writer.writeAll("\"\n");
    try writer.writeAll("            COMPREPLY=($(compgen -W \"${formats}\" -- \"${cur}\"))\n");
    try writer.writeAll("            return 0\n");
    try writer.writeAll("            ;;\n");

    // completions shell completion
    try writer.writeAll("        completions)\n");
    try writer.writeAll("            COMPREPLY=($(compgen -W \"bash zsh fish powershell\" -- \"${cur}\"))\n");
    try writer.writeAll("            return 0\n");
    try writer.writeAll("            ;;\n");

    // File-taking commands
    for (file_commands) |cmd| {
        try writer.print("        {s})\n", .{cmd});
        try writer.writeAll("            COMPREPLY=($(compgen -f -X '!*.volt' -- \"${cur}\"))\n");
        try writer.writeAll("            return 0\n");
        try writer.writeAll("            ;;\n");
    }

    try writer.writeAll("    esac\n\n");

    // Top-level completion
    try writer.writeAll("    if [ \"${COMP_CWORD}\" -eq 1 ]; then\n");
    try writer.writeAll("        COMPREPLY=($(compgen -W \"${commands}\" -- \"${cur}\"))\n");
    try writer.writeAll("        return 0\n");
    try writer.writeAll("    fi\n\n");

    // Default to file completion for unknown subcommands
    try writer.writeAll("    COMPREPLY=($(compgen -f -- \"${cur}\"))\n");
    try writer.writeAll("    return 0\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("complete -F _volt volt\n");

    return buf.toOwnedSlice();
}

/// Generate zsh completion script
pub fn generateZshCompletions(allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("#compdef volt\n");
    try writer.writeAll("# Zsh completion for Volt API Client\n");
    try writer.writeAll("# Add to ~/.zshrc: eval \"$(volt completions zsh)\"\n\n");

    try writer.writeAll("_volt() {\n");
    try writer.writeAll("    local -a _commands\n");
    try writer.writeAll("    _commands=(\n");

    for (commands, 0..) |cmd, i| {
        try writer.print("        '{s}:{s}'\n", .{ cmd, command_descriptions[i] });
    }

    try writer.writeAll("    )\n\n");

    try writer.writeAll("    local -a _export_formats\n");
    try writer.writeAll("    _export_formats=(");
    for (export_formats, 0..) |fmt, i| {
        if (i > 0) try writer.writeAll(" ");
        try writer.writeAll(fmt);
    }
    try writer.writeAll(")\n\n");

    try writer.writeAll("    _arguments -C \\\n");
    try writer.writeAll("        '1:command:->command' \\\n");
    try writer.writeAll("        '*::arg:->args'\n\n");

    try writer.writeAll("    case \"$state\" in\n");
    try writer.writeAll("        command)\n");
    try writer.writeAll("            _describe 'volt command' _commands\n");
    try writer.writeAll("            ;;\n");
    try writer.writeAll("        args)\n");
    try writer.writeAll("            case \"${words[1]}\" in\n");

    // export subcommand
    try writer.writeAll("                export)\n");
    try writer.writeAll("                    _arguments \\\n");
    try writer.writeAll("                        '1:format:($_export_formats)' \\\n");
    try writer.writeAll("                        '2:file:_files -g \"*.volt\"'\n");
    try writer.writeAll("                    ;;\n");

    // completions subcommand
    try writer.writeAll("                completions)\n");
    try writer.writeAll("                    _arguments '1:shell:(bash zsh fish powershell)'\n");
    try writer.writeAll("                    ;;\n");

    // File-taking commands
    for (file_commands) |cmd| {
        try writer.print("                {s})\n", .{cmd});
        try writer.writeAll("                    _files -g '*.volt'\n");
        try writer.writeAll("                    ;;\n");
    }

    try writer.writeAll("                *)\n");
    try writer.writeAll("                    _files\n");
    try writer.writeAll("                    ;;\n");
    try writer.writeAll("            esac\n");
    try writer.writeAll("            ;;\n");
    try writer.writeAll("    esac\n");
    try writer.writeAll("}\n\n");

    try writer.writeAll("_volt \"$@\"\n");

    return buf.toOwnedSlice();
}

/// Generate fish completion script
pub fn generateFishCompletions(allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("# Fish completion for Volt API Client\n");
    try writer.writeAll("# Save to ~/.config/fish/completions/volt.fish\n\n");

    // Disable file completions for first argument
    try writer.writeAll("complete -c volt -f\n\n");

    // Helper function to detect subcommand context
    try writer.writeAll("# Subcommand completions\n");

    for (commands, 0..) |cmd, i| {
        try writer.print(
            "complete -c volt -n \"not __fish_seen_subcommand_from {s}\" -a \"{s}\" -d \"{s}\"\n",
            .{ buildCommandList(), cmd, command_descriptions[i] },
        );
    }

    try writer.writeAll("\n# Export format completions\n");
    for (export_formats) |fmt| {
        try writer.print(
            "complete -c volt -n \"__fish_seen_subcommand_from export\" -a \"{s}\" -d \"Export as {s}\"\n",
            .{ fmt, fmt },
        );
    }

    try writer.writeAll("\n# Completions shell argument\n");
    try writer.writeAll("complete -c volt -n \"__fish_seen_subcommand_from completions\" -a \"bash\" -d \"Bash completions\"\n");
    try writer.writeAll("complete -c volt -n \"__fish_seen_subcommand_from completions\" -a \"zsh\" -d \"Zsh completions\"\n");
    try writer.writeAll("complete -c volt -n \"__fish_seen_subcommand_from completions\" -a \"fish\" -d \"Fish completions\"\n");
    try writer.writeAll("complete -c volt -n \"__fish_seen_subcommand_from completions\" -a \"powershell\" -d \"PowerShell completions\"\n");

    try writer.writeAll("\n# File completions for file-taking commands\n");
    for (file_commands) |cmd| {
        try writer.print(
            "complete -c volt -n \"__fish_seen_subcommand_from {s}\" -F -a \"(complete -C 'ls *.volt')\"\n",
            .{cmd},
        );
    }

    return buf.toOwnedSlice();
}

/// Generate PowerShell completion script
pub fn generatePowerShellCompletions(allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("# PowerShell completion for Volt API Client\n");
    try writer.writeAll("# Add to $PROFILE: volt completions powershell | Invoke-Expression\n\n");

    try writer.writeAll("Register-ArgumentCompleter -CommandName volt -ScriptBlock {\n");
    try writer.writeAll("    param($wordToComplete, $commandAst, $cursorPosition)\n\n");

    try writer.writeAll("    $commands = @{\n");
    for (commands, 0..) |cmd, i| {
        try writer.print("        '{s}' = '{s}'\n", .{ cmd, command_descriptions[i] });
    }
    try writer.writeAll("    }\n\n");

    try writer.writeAll("    $exportFormats = @(");
    for (export_formats, 0..) |fmt, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{fmt});
    }
    try writer.writeAll(")\n\n");

    try writer.writeAll("    $shellTypes = @('bash', 'zsh', 'fish', 'powershell')\n\n");

    try writer.writeAll("    $elements = $commandAst.CommandElements\n");
    try writer.writeAll("    $command = $null\n");
    try writer.writeAll("    if ($elements.Count -gt 1) {\n");
    try writer.writeAll("        $command = $elements[1].Value\n");
    try writer.writeAll("    }\n\n");

    try writer.writeAll("    if ($elements.Count -le 2) {\n");
    try writer.writeAll("        # Complete command names\n");
    try writer.writeAll("        $commands.GetEnumerator() | Where-Object { $_.Key -like \"$wordToComplete*\" } | ForEach-Object {\n");
    try writer.writeAll("            [System.Management.Automation.CompletionResult]::new($_.Key, $_.Key, 'ParameterValue', $_.Value)\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("    } else {\n");
    try writer.writeAll("        switch ($command) {\n");

    // export
    try writer.writeAll("            'export' {\n");
    try writer.writeAll("                if ($elements.Count -eq 3) {\n");
    try writer.writeAll("                    $exportFormats | Where-Object { $_ -like \"$wordToComplete*\" } | ForEach-Object {\n");
    try writer.writeAll("                        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', \"Export as $_\")\n");
    try writer.writeAll("                    }\n");
    try writer.writeAll("                } else {\n");
    try writer.writeAll("                    Get-ChildItem -Filter '*.volt' | ForEach-Object {\n");
    try writer.writeAll("                        [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ProviderItem', $_.FullName)\n");
    try writer.writeAll("                    }\n");
    try writer.writeAll("                }\n");
    try writer.writeAll("            }\n");

    // completions
    try writer.writeAll("            'completions' {\n");
    try writer.writeAll("                $shellTypes | Where-Object { $_ -like \"$wordToComplete*\" } | ForEach-Object {\n");
    try writer.writeAll("                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', \"$_ shell completions\")\n");
    try writer.writeAll("                }\n");
    try writer.writeAll("            }\n");

    // File-taking commands
    try writer.writeAll("            { $_ -in @(");
    for (file_commands, 0..) |cmd, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{cmd});
    }
    try writer.writeAll(") } {\n");
    try writer.writeAll("                Get-ChildItem -Filter '*.volt' | Where-Object { $_.Name -like \"$wordToComplete*\" } | ForEach-Object {\n");
    try writer.writeAll("                    [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ProviderItem', $_.FullName)\n");
    try writer.writeAll("                }\n");
    try writer.writeAll("            }\n");

    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn buildCommandList() []const u8 {
    // Return a static space-separated list of commands for fish completions
    return "run test bench mock export collection graphql generate init import env history lint diff version help workflow validate docs completions monitor cache ws sse auth";
}

// ── Tests ───────────────────────────────────────────────────────────────

test "bash completions contain expected keywords" {
    const result = try generateBashCompletions(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "_volt()") != null);
    try std.testing.expect(mem.indexOf(u8, result, "COMPREPLY") != null);
    try std.testing.expect(mem.indexOf(u8, result, "compgen") != null);
    try std.testing.expect(mem.indexOf(u8, result, "complete -F _volt volt") != null);
    try std.testing.expect(mem.indexOf(u8, result, "run") != null);
    try std.testing.expect(mem.indexOf(u8, result, "export") != null);
    try std.testing.expect(mem.indexOf(u8, result, "curl") != null);
}

test "zsh completions contain expected keywords" {
    const result = try generateZshCompletions(std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "#compdef volt") != null);
    try std.testing.expect(mem.indexOf(u8, result, "_arguments") != null);
    try std.testing.expect(mem.indexOf(u8, result, "_describe") != null);
    try std.testing.expect(mem.indexOf(u8, result, "run:") != null);
    try std.testing.expect(mem.indexOf(u8, result, "export)") != null);
    try std.testing.expect(mem.indexOf(u8, result, "completions)") != null);
}
