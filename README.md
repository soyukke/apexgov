# apexgov

`apexgov` is an offline Apex static checker and debug log profiler for CI/CD.

## Why

- Detect governor-risk code paths before deploy
- Track CPU/Heap budgets from Apex Debug Logs in CI
- Emit machine-readable reports (`json`, `sarif`) for pipelines

## Commands

### `check`

Static heuristics for governor/CPU/Heap anti-patterns.

```bash
zig build run -- check force-app --format text
zig build run -- check force-app --format sarif --out reports/apexgov.sarif
```

### `profile`

Offline parser for Apex debug logs with budget checks.

```bash
zig build run -- profile artifacts/logs --config apexgov.toml
zig build run -- profile artifacts/logs --format json --out reports/profile.json
zig build run -- profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
```

If budget is exceeded, the process exits with code `1`.
When `[ci].fail_on_regression = true`, baseline regressions also exit with code `1`.

## Configuration

Copy `apexgov.toml.example` to `apexgov.toml` and tune budgets.

```toml
[budget.sync]
cpu_ms = 8000
heap_bytes = 5000000

[budget.async]
cpu_ms = 50000
heap_bytes = 10000000

[ci]
fail_on_regression = true
regression_percent = 15
```

## Build and test

```bash
zig build
zig build test
```
