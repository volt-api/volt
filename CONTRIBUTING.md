# Contributing to Volt

Thanks for your interest in contributing to Volt! This document covers the basics.

## Getting Started

### Prerequisites

- [Zig 0.14.1](https://ziglang.org/download/) (exact version required)

### Build & Test

```bash
# Build
zig build

# Run tests (all 127 must pass)
zig build test

# Build release binary
zig build -Doptimize=ReleaseFast

# Run directly
zig build run -- version
```

### Project Structure

```
src/
  main.zig              CLI entry point (commands, flags, output)
  core/
    root.zig            Module registry (all exports)
    volt_file.zig       .volt format parser & serializer
    http_client.zig     HTTP execution engine
    environment.zig     Variable resolution & interpolation
    collection_runner.zig  Directory-based collection execution
    ...                 40+ modules
  tui/
    app.zig             Terminal UI application
    terminal.zig        ANSI terminal abstraction
    input.zig           Keyboard input handling
examples/
  *.volt                Example request files
```

### Coding Conventions

- Every module has `pub fn init(allocator)` / `pub fn deinit(self)` where applicable
- Use `std.ArrayList` for dynamic arrays, `std.StringHashMap` for maps
- Use `allocator.dupe()` when you need to own a copy of a string
- Use `defer` for cleanup — always
- Exhaustive `switch` on enums — no `else` branches
- Tests at the bottom of every module file
- No external dependencies — stdlib only

### Adding a Feature

1. Create the module in `src/core/`
2. Export it from `src/core/root.zig`
3. Wire it into `src/main.zig` (CLI command or integration)
4. Add tests (minimum 2 per module)
5. Run `zig build test` — all 127+ tests must pass

### Commit Messages

Use conventional style:
```
feat: add GraphQL introspection support
fix: handle empty body in curl export
docs: update README benchmarks
test: add cookie jar expiry tests
```

## Pull Requests

- One feature per PR
- Tests required
- Keep PRs small and focused
- Describe what and why in the PR body

## Reporting Issues

- Include Volt version (`volt version`)
- Include OS and Zig version
- Minimal reproduction steps
- Paste the `.volt` file if relevant (redact secrets)

## Code of Conduct

Be respectful. Be constructive. We're all here to build something great.
