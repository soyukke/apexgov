# Java CPU Calibration

Apex CPU の静的見積もり係数を、Javaのマイクロベンチから相対生成する補助ツールです。

## Files

- `src/CpuModelBench.java`: synthetic benchmark
- `run.sh`: benchmark実行 + `cpu_model.toml` 生成

## Usage

```bash
# flake環境なら jdk が入る
nix develop

# 既定出力: reports/java-calibration
./tools/java-calibration/run.sh

# 出力先指定
./tools/java-calibration/run.sh reports/java-calibration-myenv

# 係数アンカー調整
ANCHOR_SOQL_MS=30 BASE_MS=450 MAX_WEIGHT_MS=120 ITERATIONS=80000 ./tools/java-calibration/run.sh
```

## Output

- `benchmark.csv`: op別の `ns_per_iter`
- `cpu_model.toml`: `apexgov.toml` へ貼れる `[cpu.model]`

`cpu_model.toml` を `apexgov.toml` にマージすれば、`apexgov check --config` で `AG009` のCPU見積もりがその係数を使います。

## Notes

- JavaとApexの実行基盤は異なるため、絶対msではなく相対重みとして使います。
- 実際のDebug Log (`apexgov profile`) を見ながら係数を継続補正してください。
