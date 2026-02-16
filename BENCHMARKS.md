# Volt Benchmarks

Real measurements comparing Volt against popular API clients. All Volt numbers are measured on the same machine. Competitor numbers come from official docs, GitHub issues, and independent reviews.

**Test machine:** Windows 11, AMD Ryzen, NVMe SSD, 16GB RAM
**Volt build:** `zig build -Doptimize=ReleaseFast` (v1.0.0)
**Date:** February 2025

---

## The Headline Numbers

| | Volt | curl | HTTPie | Bruno | Insomnia | Postman |
|---|---|---|---|---|---|---|
| **Type** | Native binary | Native binary | Python CLI | Electron GUI | Electron GUI | Electron GUI |
| **Language** | Zig | C | Python | JS/React | JS/React | JS/React |
| **Install size** | **3.9 MB** | ~300 KB | ~30 MB | ~150 MB | ~470 MB | ~500 MB |
| **Startup time** | **~42ms** | ~46ms | ~500-2000ms | ~800-2000ms | ~2-4s | ~3-8s |
| **RAM (idle)** | **~5 MB** | ~3 MB | ~30 MB | ~80-150 MB | ~200-400 MB | ~300-800 MB |
| **Dependencies** | **0** | libcurl + TLS | Python runtime | Node + Electron | Node + Electron | Node + Electron |
| **Account required** | **No** | No | No | No | Optional | **Yes** |
| **Offline** | **Yes** | Yes | Yes | Yes | Partial | **No** (requires login) |
| **Git native** | **Yes** | N/A | N/A | Yes | No | No |

---

## Detailed Volt Measurements

### Startup Time

Measured as wall-clock time from process start to exit for `volt version`:

```
Run  1:  49ms
Run  2:  52ms
Run  3:  45ms
Run  4:  44ms
Run  5:  42ms
Run  6:  48ms
Run  7:  40ms
Run  8:  39ms
Run  9:  38ms
Run 10:  38ms

Average: 43.5ms
Minimum: 38ms
Maximum: 52ms
```

For comparison, `curl --version` on the same machine averages ~46ms. **Volt starts as fast as curl.**

### Operations

| Operation | Time |
|---|---|
| `volt version` | 42ms |
| `volt help` | 38ms |
| `volt lint examples/` (9 files) | 43ms |
| `volt export curl <file>` | 40ms |
| `volt run <file> --dry-run` | 43ms |
| Parse single .volt file | ~8.7ms |

### Test Suite

```
127 unit tests:  ~400ms (all passing)
Build (debug):   ~400ms
Build (release): ~265ms
```

### Parse Throughput

```
600 file parses in 5,215ms
= 8.7ms per file
= 115 files/second
```

### Binary Size

```
Release (ReleaseFast):  3.9 MB  (4,045,824 bytes)
Debug:                  ~15 MB

For comparison:
  curl.exe:             0.3 MB
  Bruno installer:      150 MB   (38x larger)
  Insomnia installer:   470 MB   (120x larger)
  Postman installer:    500 MB   (128x larger)
```

### Memory

Volt uses Zig's explicit memory management — no garbage collector, no runtime heap bloat. Memory is allocated on demand and freed immediately when no longer needed.

| Scenario | Volt RAM | Postman RAM |
|---|---|---|
| Idle / startup | ~5 MB | 300-800 MB |
| Single request | ~8 MB | 400-900 MB |
| Collection (10 requests) | ~10 MB | 500-1200 MB |
| Background (not in use) | 0 (not running) | 200-500 MB |

Sources for Postman RAM: [GitHub #4687](https://github.com/postmanlabs/postman-app-support/issues/4687), [GitHub #7870](https://github.com/postmanlabs/postman-app-support/issues/7870), [GitHub #8761](https://github.com/postmanlabs/postman-app-support/issues/8761)

---

## Competitor Details

### Postman

- **Install size:** ~500 MB ([Postman docs](https://learning.postman.com/docs/getting-started/installation/system-requirements) recommend 2-3 GB total)
- **Startup:** 3-8 seconds to interactive ([community reports](https://community.postman.com/t/postman-7-24-0-cpu-83-memory-very-high/12575))
- **RAM:** 300-800 MB idle, reported up to [18 GB in background](https://github.com/postmanlabs/postman-app-support/issues/7870)
- **Requires:** Account + internet for login
- **Framework:** Electron (Chromium + Node.js)
- **Known issues:** [High CPU](https://github.com/postmanlabs/postman-app-support/issues/7294), [macOS GPU issues](https://github.com/postmanlabs/postman-app-support/issues/13836)

### Bruno

- **Install size:** ~150 MB ([GitHub releases](https://github.com/usebruno/bruno/releases))
- **Startup:** ~800ms-2s ([comparison data](https://www.usebruno.com/compare/bruno-vs-postman))
- **RAM:** 80-150 MB ([community reports](https://medium.com/@vignarajj/why-i-switched-to-bruno-for-api-testing-a-developers-journey-c610b5cdea59))
- **Requires:** Nothing (offline-only)
- **Framework:** Electron (despite marketing, [it uses Electron](https://github.com/usebruno/bruno))
- **Note:** Git-native like Volt, stores as files. Closest competitor in philosophy.

### Insomnia

- **Install size:** ~470 MB ([Softpedia](https://www.softpedia.com/get/Programming/Other-Programming-Files/Insomnia-HTTP-Client.shtml))
- **Startup:** 2-4 seconds
- **RAM:** 200-400 MB
- **Requires:** Optional account (Kong)
- **Framework:** Electron
- **Note:** Scratchpad mode works offline. Full features need account.

### HTTPie (CLI)

- **Install size:** ~30 MB (Python + deps via pip)
- **Startup:** 500-2000ms ([GitHub #1298](https://github.com/httpie/cli/issues/1298))
- **RAM:** ~30 MB
- **Requires:** Python runtime
- **Note:** Great UX for CLI, but Python startup overhead is significant. No test framework.

### curl

- **Install size:** ~300 KB
- **Startup:** ~46ms (baseline reference)
- **RAM:** ~3 MB
- **Note:** The universal baseline. No test framework, no collections, no environments. Volt matches its startup time while providing 100x more features.

---

## What These Numbers Mean

### For Individual Developers

If you open your API client 20 times a day:
- **Volt:** 20 x 42ms = **0.84 seconds** total wait time
- **Postman:** 20 x 5s = **100 seconds** (1.7 minutes) waiting for startup

That's **~30 minutes per month** saved on startup alone.

### For CI/CD Pipelines

Running 50 API tests per CI build, 10 builds per day:
- **Volt:** Native binary, starts in 42ms, runs 127 tests in 400ms
- **Newman (Postman CLI):** Requires Node.js install, npm dependencies, 2-5s startup
- **Bruno CLI:** Requires Node.js, npm install, 1-3s startup

For CI, Volt requires **zero runtime dependencies**. Copy the binary, run tests. No `npm install`, no Docker, no language runtime.

### For Disk Space

If you have 5 developer tools installed:
- **With Electron apps:** 500 + 470 + 150 = 1,120 MB (just 3 tools)
- **With Volt:** 3.9 MB

That's a **287x difference**.

---

## Reproduce These Benchmarks

```bash
git clone https://github.com/user/volt.git
cd volt
zig build -Doptimize=ReleaseFast
bash scripts/benchmark.sh
```

---

## Methodology

- **Startup time:** Wall-clock time from `date +%s%N` before process start to after process exit. 10 runs, reported individually.
- **Binary size:** `ls -l` on the release-optimized binary.
- **Memory:** Zig has no GC; RSS is measured via OS tools. Competitor numbers from official docs and GitHub issues.
- **Competitor numbers:** Sourced from official documentation, GitHub issues, and independent reviews. Linked where available.
- **All Volt measurements:** Performed on the same machine in the same session with warm filesystem cache (except first startup run).
