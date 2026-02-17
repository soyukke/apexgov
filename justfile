default:
  @just --list

periodic-transpile:
  @just _periodic false

periodic-transpile-strict:
  @just _periodic true

_periodic strict:
  #!/usr/bin/env bash
  set -euo pipefail

  targets_file="${APEXGOV_PERIODIC_TARGETS_FILE:-.local-fixtures/periodic-targets.txt}"
  if [[ ! -f "${targets_file}" ]]; then
    echo "targets file not found: ${targets_file}" >&2
    echo "create it from template: cp tools/periodic-targets.example.txt ${targets_file}" >&2
    exit 2
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  out_root="reports/apex-transpile-periodic/${stamp}"
  mkdir -p "${out_root}"

  echo "[apexgov] periodic transpile check"
  echo "strict: {{strict}}"
  echo "targets_file: ${targets_file}"
  echo "out_root: ${out_root}"
  echo

  count=0
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="${raw_line%%$'\r'}"
    [[ -z "${line// }" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    source="${line%%|*}"
    subpath=""
    if [[ "${line}" == *"|"* ]]; then
      subpath="${line#*|}"
    fi

    source="$(printf '%s' "${source}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    subpath="$(printf '%s' "${subpath}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${source}" ]] && continue

    cmd=(./tools/transpile-external.sh "${source}" --out-root "${out_root}")
    if [[ -n "${subpath}" ]]; then
      cmd+=(--subpath "${subpath}")
    fi
    if [[ "{{strict}}" == "true" ]]; then
      cmd+=(--strict)
    fi

    echo "[apexgov] target: ${source}${subpath:+ | subpath: ${subpath}}"
    "${cmd[@]}"
    echo
    count=$((count + 1))
  done < "${targets_file}"

  if [[ "${count}" -eq 0 ]]; then
    echo "no targets found in: ${targets_file}" >&2
    exit 2
  fi

  echo "[apexgov] done: ${out_root}"
