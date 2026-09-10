#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
native_root="$(cd "$script_dir/.." && pwd)"
resources_dir="${1:?destination Resources directory is required}"
lint_strings=0
if [[ "$(uname -s)" == Darwin ]]; then
  command -v plutil >/dev/null 2>&1
  lint_strings=1
fi

mkdir -p "$resources_dir"

copy_lproj() {
  local source_dir="$1"
  local destination_dir="$2"
  local tmp_dir
  local source_resource
  local relative_path

  test -s "$source_dir/InfoPlist.strings"
  mkdir -p "$destination_dir"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumen-native-lproj.XXXXXX")"
  trap 'rm -rf -- "$tmp_dir"' RETURN
  cp -R "$source_dir/." "$tmp_dir/"
  cp -R "$tmp_dir/." "$destination_dir/"

  while IFS= read -r -d '' source_resource; do
    relative_path="${source_resource#"$source_dir/"}"
    test -f "$destination_dir/$relative_path"
    cmp -s "$source_resource" "$destination_dir/$relative_path"
  done < <(find "$source_dir" -type f -print0 | sort -z)
  if [[ "$lint_strings" == 1 ]]; then
    plutil -lint "$source_dir/InfoPlist.strings"
    plutil -lint "$destination_dir/InfoPlist.strings"
  fi
}

while IFS= read -r -d '' lproj_dir; do
  copy_lproj "$lproj_dir" "$resources_dir/$(basename "$lproj_dir")"
done < <(find "$native_root/Packaging" -maxdepth 1 -type d -name '*.lproj' -print0 | sort -z)
