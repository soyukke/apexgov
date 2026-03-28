#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="$repo_root/.local-fixtures/apex/repos"
default_out_root="$repo_root/reports/apex-transpile-external"
nix_bin=""

if command -v nix >/dev/null 2>&1; then
  nix_bin="$(command -v nix)"
elif [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
  nix_bin="/nix/var/nix/profiles/default/bin/nix"
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi

if ! command -v zig >/dev/null 2>&1; then
  if [[ -n "$nix_bin" && "${APEXGOV_IN_NIX_DEV:-}" != "1" ]]; then
    echo "zig not found on PATH; re-running inside nix develop"
    export APEXGOV_IN_NIX_DEV=1
    exec "$nix_bin" develop -c "$0" "$@"
  fi
  echo "zig not found on PATH. Run under nix develop or install zig." >&2
  exit 127
fi

usage() {
  cat <<'USAGE'
usage: transpile-external.sh [options] <source>

source:
  - local path (Apex project root or classes dir)
  - git URL (https://..., ssh://..., git@...)

options:
  --subpath PATH   path under source to transpile (e.g. force-app/main/default/classes)
  --ref REF        git ref for git URL source (branch/tag/commit)
  --package NAME   Java package for transpile output (default: generated)
  --out-root DIR   output root directory (default: reports/apex-transpile-external)
  --run-tests      run `emulate test` after transpile
  --best-effort    pass `--best-effort` when --run-tests is enabled
  --nix            pass `--nix` when running emulate test
  --strict         fail when unsupported statements exist
  -h, --help       show this help

examples:
  ./tools/transpile-external.sh https://example.com/your-apex-repo.git --subpath force-app/main/default/classes
  ./tools/transpile-external.sh /path/to/sfdx-project --subpath force-app/main/default/classes --strict
USAGE
}

is_git_source() {
  local src="$1"
  [[ "$src" =~ ^https?:// ]] || [[ "$src" =~ ^ssh:// ]] || [[ "$src" =~ ^git@ ]]
}

sanitize_label() {
  local raw="$1"
  local out
  out="$(printf '%s' "$raw" | tr '/:@ ' '____' | tr -cd '[:alnum:]_.-')"
  if [[ -z "$out" ]]; then
    out="external"
  fi
  printf '%s' "$out"
}

source_arg=""
subpath=""
ref=""
package_name="generated"
out_root="$default_out_root"
strict=false
run_tests=false
best_effort=false
use_nix=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subpath)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --subpath" >&2
        exit 2
      fi
      subpath="$2"
      shift 2
      ;;
    --ref)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --ref" >&2
        exit 2
      fi
      ref="$2"
      shift 2
      ;;
    --package)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --package" >&2
        exit 2
      fi
      package_name="$2"
      shift 2
      ;;
    --out-root)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --out-root" >&2
        exit 2
      fi
      out_root="$2"
      shift 2
      ;;
    --strict)
      strict=true
      shift
      ;;
    --run-tests)
      run_tests=true
      shift
      ;;
    --best-effort)
      best_effort=true
      shift
      ;;
    --nix)
      use_nix=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$source_arg" ]]; then
        echo "multiple source arguments are not supported" >&2
        exit 2
      fi
      source_arg="$1"
      shift
      ;;
  esac
done

if [[ -z "$source_arg" ]]; then
  usage
  exit 2
fi

resolved_source=""
label=""
if is_git_source "$source_arg"; then
  mkdir -p "$cache_root"
  repo_name="$(basename "$source_arg")"
  repo_name="${repo_name%.git}"
  if [[ -z "$repo_name" ]]; then
    repo_name="external-repo"
  fi
  repo_dir="$cache_root/$repo_name"

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "cloning: $source_arg -> $repo_dir"
    git clone --depth 1 "$source_arg" "$repo_dir"
  else
    echo "using cached repo: $repo_dir"
  fi

  if [[ -n "$ref" ]]; then
    echo "checking out ref: $ref"
    git -C "$repo_dir" fetch --depth 1 origin "$ref"
    git -C "$repo_dir" checkout --detach FETCH_HEAD
  fi

  resolved_source="$repo_dir"
  label="$(sanitize_label "$repo_name${ref:+-$ref}")"
else
  if [[ ! -e "$source_arg" ]]; then
    echo "source path not found: $source_arg" >&2
    exit 2
  fi
  resolved_source="$source_arg"
  label="$(sanitize_label "$(basename "$source_arg")")"
fi

if [[ -n "$subpath" ]]; then
  target_path="$resolved_source/$subpath"
else
  target_path="$resolved_source"
fi

if [[ ! -d "$target_path" && ! -f "$target_path" ]]; then
  echo "target path not found: $target_path" >&2
  exit 2
fi

cls_count="$(find "$target_path" -type f -name '*.cls' | wc -l | tr -d ' ')"
if [[ "$cls_count" == "0" ]]; then
  echo "no Apex .cls files found under: $target_path" >&2
  exit 2
fi

out_dir="$out_root/$label"
# Avoid stale Java artifacts from previous runs (e.g. renamed/removed sources)
# because emulate transpile only overwrites generated targets.
rm -rf "$out_dir"
mkdir -p "$out_dir"

cmd=(
  zig build run -- emulate transpile
  "$target_path"
  --out "$out_dir"
  --package "$package_name"
  --overwrite
)
if [[ "$strict" == "true" ]]; then
  cmd+=(--strict)
fi

echo "transpile target: $target_path"
echo "output dir: $out_dir"
echo "apex files: $cls_count"
"${cmd[@]}"

if [[ "$run_tests" == "true" ]]; then
  # Generate picklist registry from metadata XML if objects/ directories exist.
  picklist_script="$repo_root/tools/java-emulation/generate-picklist-registry.sh"
  picklist_java="$out_dir/$package_name/PicklistRegistry.java"
  if [[ -x "$picklist_script" ]]; then
    # Search for objects/ under the resolved source (project root).
    if find "$resolved_source" -path "*/objects/*/fields/*.field-meta.xml" -print -quit 2>/dev/null | grep -q .; then
      echo "generating picklist registry from metadata..."
      "$picklist_script" "$resolved_source" "$picklist_java"
    fi
  fi

  test_out="$out_dir/test"
  test_cmd=(
    zig build run -- emulate test
    "$out_dir"
    --out "$test_out"
  )
  if [[ "$best_effort" == "true" ]]; then
    test_cmd+=(--best-effort)
  fi
  # External tests don't define their own Schema so register standard defaults
  test_cmd+=(--register-standard-schema)
  if [[ "$use_nix" == "true" ]]; then
    test_cmd+=(--nix)
  fi

  echo "test output dir: $test_out"
  "${test_cmd[@]}"
fi
