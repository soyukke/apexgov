# apexgov

[日本語版 README はこちら](README_ja.md)

`apexgov` is an offline static checker and debug-log profiler for Salesforce Apex, designed for CI/CD pipelines.

## Why

- Detect governor-risk code paths before deploy
- Catch SOQL / DML / SOSL / Callout / Messaging operations inside loops with limit-aware warnings
- Estimate loop upper bounds from guards (`for`/`while`/`do-while`, e.g. `if (n > 200) return`) and flag likely limit-exceed points
- Follow helper-method call chains across files/classes to catch indirect SOQL/DML in loops
- Multiply callee-side loop effects into governor estimates (e.g. nested helper loops)
- Use method arity and inferred literal/new-expression/local-variable types to reduce false positives on overloaded calls
- Resolve interface/inheritance-based dynamic dispatch more accurately (`implements` / `extends`)
- Track CPU/Heap budgets from Apex Debug Logs in CI
- Split multi-transaction debug logs per transaction and compare regressions transaction-by-transaction
- Emit machine-readable reports (`json`, `sarif`) for pipelines
- Transpile Apex to Java and run `@Test` methods locally with governor-limit emulation

## Static Analysis Rules

| ID | Detection Target |
|---|---|
| AG001 | Nested loops |
| AG002 | SOQL inside loops |
| AG003 | DML inside loops |
| AG004 | JSON serialize/deserialize inside loops |
| AG005 | clone/deepClone inside loops |
| AG006 | Collection allocation inside loops |
| AG007 | String concatenation inside loops |
| AG008 | SOSL inside loops |
| AG009 | Heuristic CPU estimate |
| AG010 | HTTP callout inside loops |
| AG011 | Messaging.sendEmail inside loops |

## LSP (Language Server)

apexgov includes a built-in Apex language server. It provides diagnostics (governor limit violations + parse errors), code completion, go to definition, references, hover, rename, semantic highlighting, and more.

```bash
apexgov lsp   # Starts the LSP server (stdio)
```

Neovim + lazy.nvim quick setup (prebuilt binary, no Zig required):

```lua
{ "soyukke/apexgov", build = function(p)
    local u = vim.uv.os_uname()
    local os = u.sysname == "Darwin" and "darwin" or "linux"
    local arch = u.machine == "arm64" and "aarch64" or "x86_64"
    vim.fn.mkdir(p.dir.."/bin", "p")
    vim.fn.system(("curl -sL https://github.com/soyukke/apexgov/releases/latest/download/apexgov-%s-%s.tar.gz | tar xz -C %s/bin"):format(os, arch, p.dir))
  end, config = function(p)
    vim.filetype.add({ extension = { cls = "apex", trigger = "apex" } })
    vim.lsp.config("apexgov", { cmd = { p.dir.."/bin/apexgov", "lsp" },
      filetypes = { "apex" }, root_markers = { "sfdx-project.json", ".git" } })
    vim.lsp.enable("apexgov")
end }
```

See [docs/lsp-setup.md](docs/lsp-setup.md) for detailed VS Code and Neovim setup instructions.

## Commands

### `check`

Static heuristics for governor / CPU / Heap anti-patterns.

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

### `emulate`

Java-based auxiliary emulation features.

```bash
zig build run -- emulate java
zig build run -- emulate java reports/java-calibration-local --iterations 80000 --nix
zig build run -- emulate test tools/java-emulation/examples --out reports/java-emulation --nix
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated --strict
```

### `typegen`

Generate LWC TypeScript type definitions from SFDX metadata. Org connection not required — fully offline.

```bash
zig build run -- typegen my-sfdx-project --out .sfdx/typings/lwc
```

Generated files:

| Module | Source | Output |
|---|---|---|
| `@salesforce/schema/Obj.Field` | `*.field-meta.xml` | `schema.d.ts` |
| `@salesforce/label/c.XXX` | `CustomLabels.labels-meta.xml` | `customlabels.d.ts` |
| `@salesforce/resourceUrl/XXX` | `*.resource-meta.xml` | `{name}.resource.d.ts` |
| `@salesforce/messageChannel/XXX__c` | `*.messageChannel-meta.xml` | `{name}.messageChannel.d.ts` |
| `@salesforce/contentAssetUrl/XXX` | `*.asset-meta.xml` | `{name}.asset.d.ts` |
| `@salesforce/apex/Class.method` | `*.cls` (`@AuraEnabled`) | `apex.d.ts` |

Output for `resource`, `messageChannel`, `asset`, and `customlabels` is byte-identical with the official `@salesforce/lwc-language-server`. Files are processed in alphabetical path order for deterministic output.

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

## Build and Test

Requires [Zig](https://ziglang.org/) (0.15+). Alternatively, use `nix develop` for a reproducible environment with Zig + ZLS + JDK 21.

```bash
zig build          # Build (zig-out/bin/apexgov)
zig build test     # Run all unit tests
zig build run -- <subcommand>  # Build & run
```

## Apex Language Coverage

The transpiler's Apex language coverage is tracked in `docs/apex-language-coverage.md`.

Non-best-effort snapshot (as of 2026-03-07):

- `apex-recipes`: `322/322`
- `fflib-apex-mocks`: `471/471`
- `fflib-apex-common + fflib-apex-mocks`: `158/158`
- `fflib-apex-common-samplecode + fflib-apex-common + fflib-apex-mocks`: `16/16`

When adding features via PR, please update the coverage table alongside implementation and tests.

## Local Validation Fixtures

`examples/apex-validation` contains sample Apex projects and logs for `check` / `profile` validation.
See `examples/apex-validation/README.md` for instructions.

## External Apex Validation (git-ignored)

You can validate transpilation against real-world Apex codebases using git-ignored inputs.
`./tools/transpile-external.sh` accepts a git URL or local path and runs `emulate transpile`.

```bash
# Clone a public repo and validate (cloned into .local-fixtures/)
./tools/transpile-external.sh \
  https://example.com/your-apex-repo.git \
  --subpath force-app/main/default/classes

# Validate a local SFDX project in strict mode
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --strict

# Transpile and then run local emulation tests
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --run-tests --nix

# Best-effort mode for projects with unresolved sources
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --run-tests --best-effort --nix
```

- Cache / clone directory: `.local-fixtures/apex/repos/` (git-ignored)
- Output directory: `reports/apex-transpile-external/<label>/`

## Periodic Transpile Check (just)

Periodic checks across multiple repositories are managed via a local targets file (git-ignored).

```bash
cp tools/periodic-targets.example.txt .local-fixtures/periodic-targets.txt
# Edit .local-fixtures/periodic-targets.txt to configure targets
just periodic-transpile
just periodic-transpile-strict
```

- Default targets file: `.local-fixtures/periodic-targets.txt` (git-ignored)
- Override via environment variable `APEXGOV_PERIODIC_TARGETS_FILE`
- Output directory: `reports/apex-transpile-periodic/<timestamp>/`

## Java Calibration

`tools/java-calibration` contains a micro-benchmark for generating relative CPU cost coefficients.

```bash
nix develop
./tools/java-calibration/run.sh
# Or via CLI
zig build run -- emulate java --nix
```

Merge the generated `cpu_model.toml`'s `[cpu.model]` section into `apexgov.toml` to use it for AG009 CPU estimates.

## Java Test Emulation

`tools/java-emulation` contains a lightweight runner that executes `@Test` methods locally and detects CPU/Heap limit violations.

```bash
zig build run -- emulate test --nix
zig build run -- emulate test reports/apex-transpile-external/my-repo --nix
# For projects with unresolved sources
zig build run -- emulate test reports/apex-transpile-external/my-repo --best-effort --nix
CPU_LIMIT_MS=8000 HEAP_LIMIT_BYTES=5000000 ./tools/java-emulation/run-tests.sh
SOQL_NULL_ORDER_DEFAULT=DIRECTIONAL ./tools/java-emulation/run-tests.sh
```

- `--best-effort` incrementally replaces unresolvable sources with placeholder stubs so that compilable `@Test` methods run first (original sources are not modified).
- Placeholder sources are listed in `OUT_DIR/compile-fallbacks.txt`.
- Sources that still fail to compile are listed in `OUT_DIR/compile-failures.txt`.

Key runtime capabilities:

- `Limits` API (`get*`) and `Test.startTest/stopTest`
- `Test.runAs(...)` / `UserInfo.getUserId()/getUsername()/getUserName()/getProfileId()` context switching (including `Schema` profile context)
- `Test.loadData(sobjectType, csvPath)` for CSV fixture loading
- `Test.setMock(...)` + `Http.send` / `WebServiceCallout.invoke` mock execution
- `@Future` / Queueable / Batch / Schedulable simple flush on `stopTest()`
- `QueryLocatorBatchable` scope splitting with `execute(List<ApexSObject>)`
- Independent `Limits` context for `start/execute/finish`
- `BatchContext.getJobId()/getScopeIndex()/getTotalScopes()/getScopeSize()/getScopeRecordCount()/getPhase()`
- `Trigger` before/after context reproduction
- `Database` + `ApexSObject` in-memory CRUD (including `merge`) / SOQL subset
- `Database.queryWithBinds/countQueryWithBinds` (`:name` bind, `IN :names` collection bind)
- `Database.getQueryLocator/getQueryLocatorWithBinds`
- SOQL trailing `FOR UPDATE` / `FOR VIEW` / `FOR REFERENCE` / `ALL ROWS` ignored during evaluation
- `GROUP BY` / `HAVING` / aggregate (`COUNT/COUNT_DISTINCT/SUM/AVG/MIN/MAX`) / `OFFSET`
- Date literals (`TODAY` / `LAST_N_DAYS:n` etc.) and unquoted ISO date/datetime literals
- `WHERE` `IS NULL` / `IS NOT NULL`
- Relationship paths (`Owner.Name`, `Parent__r.Name`) in `WHERE/ORDER BY/GROUP BY/HAVING`
- `Database.setSavepoint()/rollback()`
- `Database.*(records, allOrNone)` + `SaveResult`
- `Database.merge(master, duplicates, allOrNone)` + `MergeResult` (including related reparent IDs)
- `Schema` validation for custom objects: required/type/maxLength/restricted picklist/precision(scale)/lookup reference/unique/externalId
- Auto-firing registered triggers on `Database` CRUD (`upsert` / `merge` included)
- Related row reparenting on `merge` with auto-firing of `before/after update` triggers on related objects
- SOQL semi-join (`WHERE Id IN (SELECT ...)` / `NOT IN`) and child subquery (`SELECT ..., (SELECT ... FROM Contacts)`) subset support (schema metadata relationship name resolution preferred)

See `tools/java-emulation/README.md` for details.

## Apex-to-Java Transpile (Scaffold)

`apexgov emulate transpile` auto-generates Java class scaffolds from Apex `.cls` files.

Key transformations:

- `@IsTest` → `@Test`
- Method signatures (return type / parameters / static), constructors, class fields / `{ get; set; }` property scaffolds
- `System.assert*` → `SystemAssert.*`, `Assert.*` / `System.Assert.*` → `ApexAssert.*`, `System.debug(...)` → `System.out.println(...)`
- `switch on / when` → Java `switch` / `case ... ->` / `default ->`
- `when Account acc` → `switch (ApexSwitch.typeName(...))` + `case "Account"`
- `record instanceof Account` → `"Account".equals(ApexSwitch.typeName(record))`
- Negation/compound `instanceof` expressions (e.g. `!(record instanceof Contact)`, `record instanceof A || record instanceof B`); `instanceof SObject` → `instanceof ApexSObject`
- `do { ... } while (...)` tail normalization to Java do-while form
- `String.isBlank/isNotBlank/isEmpty/isNotEmpty/join/escapeSingleQuotes` → `ApexStrings.*`
- `List/Map/Set` declarations, constructors, and literals (`new List<T>{...}`) → Java collections (`ArrayList/LinkedHashMap/LinkedHashSet`)
- `new Map<Id, Account>(records)` / `new Map<Id, Account>(existingMap)` → `ApexCollections.toIdMap(...)`
- Named-arg style SObject constructors (`new Task(Subject='x', WhatId=...)`) → `ApexSObject.of(...).set(...)`
- `[SELECT ...]` (single/multi-line) → `Database.query(...)`; single SObject assignment → `ApexCollections.firstOrNull(Database.query(...))`
- `[SELECT ...]` passed to `Database.getQueryLocator/countQuery/queryWithBinds` → normalized query strings
- `insert/update/upsert/delete/undelete/merge` (including `upsert ... ExternalId__c`) → `Database.*` calls
- `merge` handles `merge master dup` / `merge master dup1 dup2` / `merge master, dup1, dup2`
- Unresolved types fall back to `ApexSObject`; SObject-style field access (`record.Id`) → `record.getAs("Id")`
- Unconverted lines (comment fallback) output as `file:line [method] reason: statement`
- `--strict` mode fails with exit code 1 if any unconverted lines remain

```bash
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated --strict
```

If `[APEX_PATHS...]` is omitted, the tool uses `force-app/main/default/classes` if it exists, otherwise falls back to the bundled validation fixtures (`examples/apex-validation/...`).

## License

MIT License (`LICENSE`)
