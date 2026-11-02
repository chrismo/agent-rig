#!/usr/bin/env bats
# Every script that runs super pins its superdb version, so a global asdf
# upgrade cannot change what it runs.
#
# Run with: bats test/superdb-pin.bats

ROOT="$BATS_TEST_DIRNAME/.."

super_scripts() {
  local f
  git -C "$ROOT" ls-files -- bin hooks statusline install.sh tab-status shell lib |
    while IFS= read -r f; do
      [[ "$f" == *.bats || "$f" == *.md || "$f" == *.json ]] && continue
      head -1 "$ROOT/$f" | grep -qE '^#!.*(bash|sh)' || [[ "$f" == *.sh ]] || continue
      grep -vE '^\s*#' "$ROOT/$f" | grep -qw super && echo "$f"
    done
}

@test "finds the scripts it is meant to police" {
  run super_scripts
  [[ "$output" == *"install.sh"* ]]
  [[ "$output" == *"bin/agent-read"* ]]
  [[ "$output" == *"statusline/plugins.d/2.10-context"* ]]
}

@test "each one exports ASDF_SUPERDB_VERSION before it first uses super" {
  local f pin first bad=()
  while IFS= read -r f; do
    pin=$(grep -nE '^\s*export ASDF_SUPERDB_VERSION=[0-9.]+\s*$' "$ROOT/$f" | head -1 | cut -d: -f1)
    first=$(grep -nvE '^\s*#' "$ROOT/$f" | grep -w super | grep -v ASDF_SUPERDB_VERSION | head -1 | cut -d: -f1)
    if [[ -z "$pin" ]] || ((pin > first)); then bad+=("$f"); fi
  done < <(super_scripts)
  ((${#bad[@]} == 0)) || { printf 'not pinned before first use: %s\n' "${bad[@]}"; false; }
}
