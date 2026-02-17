#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="$repo_root/.local-fixtures/apex/repos"
default_out_root="$repo_root/reports/apex-transpile-external"

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
