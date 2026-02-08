# apexgov

`apexgov` is an offline Apex static checker and debug log profiler for CI/CD.

## Why

- Detect governor-risk code paths before deploy
- Estimate loop upper bounds from guards (for example `if (n > 200) return`) and show likely limit exceed points
- Follow helper method call chains across files/classes to catch indirect SOQL/DML in loops
- Multiply callee-side loop effects into governor estimates (for example nested helper loops)
- Use method arity (argument count) to reduce false positives on overloaded calls
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

[cpu.model]
base_ms = 500
soql_ms = 35
dml_ms = 25
json_ms = 8
clone_ms = 4

[ci]
fail_on_regression = true
regression_percent = 15
```

## Build and test

```bash
zig build
zig build test
```

## Local validation fixtures

`/Users/soyukke/dev/zig/apexgov/examples/apex-validation` に、`check/profile` の再現用Apexプロジェクトとログを置いています。  
手順は `/Users/soyukke/dev/zig/apexgov/examples/apex-validation/README.md` を参照してください。

## Java Calibration

`/Users/soyukke/dev/zig/apexgov/tools/java-calibration` に、CPU係数の相対生成ツールがあります。

```bash
nix develop
./tools/java-calibration/run.sh
```

生成された `cpu_model.toml` の `[cpu.model]` を `apexgov.toml` にマージすると、`AG009` のCPU見積もりで利用されます。
