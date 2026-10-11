#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Test suite for bin/pi-sync.
#
# pi (@earendil-works/pi-coding-agent) records its installed packages in
# ~/.pi/agent/settings.json under `packages`, alongside settings that are
# machine-local (theme, lastChangelogVersion) and credentials that live next to
# it in auth.json. So the file itself is not something this repo can own or
# symlink — only the package list is portable.
#
# pi/packages.txt is that portable half, and this script is the one-way apply:
# manifest -> machine. It never removes, because the manifest is agent-rig's
# opinion and the machine may have packages installed for a reason this repo
# knows nothing about; those are reported so they can be adopted deliberately.
#
# Like bin/lemma-install and unlike hooks/*, this is human-invoked: it fails
# loudly and exits non-zero. `pi install` reaches the network, which is why
# install.sh only symlinks this script and never runs it.

S="$BATS_TEST_DIRNAME/pi-sync"

setup() {
  export AGENT_RIG_PI_SETTINGS="$BATS_TEST_TMPDIR/pi-settings.json"
  export AGENT_RIG_PI_MANIFEST="$BATS_TEST_TMPDIR/packages.txt"

  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
}

# A `pi` stub that records its argv. Exits 0, or fails for the sources named in
# $1 (space separated) so a test can simulate one package failing to install.
stub_pi() {
  local failing="${1:-}"
  cat > "$STUB/pi" <<EOF
#!/usr/bin/env bash
printf 'pi %s\n' "\$*" >> "$STUB_LOG"
for f in $failing; do
  [[ "\$*" == *"\$f"* ]] && exit 1
done
exit 0
EOF
  chmod +x "$STUB/pi"
}

# Narrow PATH to the stubs plus system dirs. `command -v` is satisfied by any
# executable file, so the only honest simulation of "pi is not installed" is a
# PATH it genuinely is not on. super is a real dependency of the script and
# lives in the same homebrew dir pi does, so link it through explicitly.
only_stubs() {
  ln -sf "$(command -v super)" "$STUB/super"
  export PATH="$STUB:/usr/bin:/bin"
}

settings() { printf '%s\n' "$1" > "$AGENT_RIG_PI_SETTINGS"; }
manifest() { printf '%s\n' "$1" > "$AGENT_RIG_PI_MANIFEST"; }

installed_sources() {
  grep '^pi install' "$STUB_LOG" 2>/dev/null | awk '{print $3}'
}

# ── Preflight ───────────────────────────────────────────────────────────────

@test "fails loudly when pi is not installed" {
  manifest 'npm:pi-web-access'
  only_stubs
  run -1 "$S"
  [[ "$output" == *"pi"* ]] || false
  [[ "$output" == *"npm"* || "$output" == *"install"* ]]
}

@test "fails loudly when the manifest is missing" {
  stub_pi
  rm -f "$AGENT_RIG_PI_MANIFEST"
  run -1 "$S"
  [[ "$output" == *"$AGENT_RIG_PI_MANIFEST"* ]]
}

@test "defaults to the manifest shipped in the repo" {
  stub_pi
  unset AGENT_RIG_PI_MANIFEST
  settings '{"packages":[]}'
  # Exit 1 because this temp settings file lists nothing: every package in the
  # repo manifest reads as missing. Naming one of them is what proves the repo
  # file was actually read, rather than merely not-not-found.
  run -1 "$S" --check
  [[ "$output" == *"npm:pi-web-access"* ]] || false
}

@test "finds the repo manifest when invoked through a symlink" {
  # install.sh links this script into ~/.local/bin, so on every real run
  # $BASH_SOURCE is the symlink, not the file in the repo. Resolving only the
  # link's *directory* lands in ~/.local/bin and the manifest is not found.
  stub_pi
  unset AGENT_RIG_PI_MANIFEST
  settings '{"packages":[]}'
  ln -s "$S" "$BATS_TEST_TMPDIR/pi-sync"
  run -1 "$BATS_TEST_TMPDIR/pi-sync" --check
  # A positive assertion: landing in the wrong directory cannot produce this.
  [[ "$output" == *"npm:pi-web-access"* ]] || false
}

# ── Applying the manifest ───────────────────────────────────────────────────

@test "installs a manifest package that pi does not have" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"theme":"dark","packages":[]}'
  run -0 "$S"
  [[ "$(installed_sources)" == "npm:pi-web-access" ]]
}

@test "does not reinstall a package pi already has" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"packages":["npm:pi-web-access"]}'
  run -0 "$S"
  [ ! -s "$STUB_LOG" ] || [[ "$(installed_sources)" == "" ]]
}

@test "installs only the missing half of a partly-satisfied manifest" {
  stub_pi
  manifest 'npm:pi-web-access
npm:pi-subagents'
  settings '{"packages":["npm:pi-web-access"]}'
  run -0 "$S"
  [[ "$(installed_sources)" == "npm:pi-subagents" ]]
}

@test "treats a missing settings file as a machine with no packages" {
  stub_pi
  manifest 'npm:pi-web-access'
  rm -f "$AGENT_RIG_PI_SETTINGS"
  run -0 "$S"
  [[ "$(installed_sources)" == "npm:pi-web-access" ]]
}

@test "ignores comments and blank lines in the manifest" {
  stub_pi
  manifest '# pi packages

npm:pi-web-access   # trailing note
'
  settings '{"packages":[]}'
  run -0 "$S"
  [[ "$(installed_sources)" == "npm:pi-web-access" ]]
}

@test "treats a settings file with no packages key as no packages" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"theme":"dark"}'
  run -0 "$S"
  [[ "$(installed_sources)" == "npm:pi-web-access" ]]
}

@test "refuses when the settings file exists but cannot be read" {
  # A missing settings.json genuinely means "no packages installed". A corrupt
  # one means "unknown", and answering it as "none" is the fail-open direction:
  # --check would call every manifest package missing, and a plain run would
  # reinstall all of them over the network on the strength of a bad read.
  stub_pi
  manifest 'npm:pi-web-access'
  settings 'not json at all'
  run -1 "$S"
  [[ "$output" == *"$AGENT_RIG_PI_SETTINGS"* ]] || false
  [ ! -s "$STUB_LOG" ]
}

@test "reads a manifest whose last line has no trailing newline" {
  stub_pi
  printf 'npm:pi-web-access' > "$AGENT_RIG_PI_MANIFEST"
  settings '{"packages":[]}'
  run -0 "$S"
  [[ "$(installed_sources)" == "npm:pi-web-access" ]]
}

# ── Drift the other way ─────────────────────────────────────────────────────

@test "reports packages installed on the machine but absent from the manifest" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"packages":["npm:pi-web-access","npm:pi-something-local"]}'
  run -0 "$S"
  [[ "$output" == *"npm:pi-something-local"* ]]
}

@test "never removes a package that is not in the manifest" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"packages":["npm:pi-web-access","npm:pi-something-local"]}'
  run -0 "$S"
  [[ "$output" != *"pi remove"* ]] || false
  ! grep -q 'pi remove\|pi uninstall' "$STUB_LOG" 2>/dev/null
}

# ── --check ─────────────────────────────────────────────────────────────────

@test "--check reports what is missing without installing, and exits non-zero" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"packages":[]}'
  run -1 "$S" --check
  [[ "$output" == *"npm:pi-web-access"* ]] || false
  [ ! -s "$STUB_LOG" ]
}

@test "--check exits 0 when the machine already satisfies the manifest" {
  stub_pi
  manifest 'npm:pi-web-access'
  settings '{"packages":["npm:pi-web-access"]}'
  run -0 "$S" --check
}

# ── Failure reporting ───────────────────────────────────────────────────────

@test "a failing install does not stop the rest, and the run exits non-zero" {
  stub_pi 'pi-web-access'
  manifest 'npm:pi-web-access
npm:pi-subagents'
  settings '{"packages":[]}'
  run -1 "$S"
  [[ "$(installed_sources)" == *"npm:pi-subagents"* ]] || false
  [[ "$output" == *"npm:pi-web-access"* ]]
}
