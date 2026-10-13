# Harness and settings for the PR pipeline. Sourced by bin/pr-config, pr-act
# and pr-watch; needs bash 5, jq and super. See docs/pr-workflow/design.md,
# "Config files".
#
# Every function returns 1 on an error (message on stderr) and never exits:
# callers run them as `x=$(prc_...) || die`, where errexit is off inside, so
# each step checks its own status. prc_setting returns 3 for a key with no
# value and no default.

PRC_DEFAULTS='{"harness": "claude",
  "settings": {"remote": "origin", "stepTimeout": 1800, "interval": 300, "replyPrefix": "🤖 ",
               "verify": "", "notify": "", "botLogin": []}}'
PRC_SKELETON='{"harness": "claude", "harnesses": {"claude": {}, "pi": {}}, "steps": {}, "settings": {}}'

prc_err() { echo "pr-config: $*" >&2; return 1; }

prc_global_file() { echo "${PR_TEND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/pr-tend/config.json}"; }

prc_branch_file() { # <branch>
  local dir name=${1//[%]/%25}
  dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { prc_err "not a git repository"; return; }
  echo "$dir/pr-tend/${name//\//%2F}.json"
}

# prc_layer <file>: its JSON, or {} when it doesn't exist.
prc_layer() {
  [[ -e $1 ]] || { echo '{}'; return 0; }
  jq -e 'type == "object"' "$1" >/dev/null || { prc_err "not a JSON object: $1"; return; }
  cat "$1"
}

prc_branch_arg() { # <branch-or-empty>
  local b=$1
  [[ -n $b ]] || b=$(git branch --show-current 2>/dev/null) || b=
  [[ -n $b ]] || { prc_err "detached HEAD; name a branch"; return; }
  echo "$b"
}

# Duplicated from dscout bin/lib/superdb.sh. The asdf shim re-resolves on every
# call (~14x slower), so call the pinned install directly; fall back to `super`
# on PATH when no pinned install exists.
prc_superdb_binary() {
  local version=${ASDF_SUPERDB_VERSION:-} bin
  [[ -n $version ]] || version=$(awk '$1 == "superdb" { print $2 }' "$HOME/.tool-versions" 2>/dev/null) || version=
  bin="${ASDF_DATA_DIR:-$HOME/.asdf}/installs/superdb/$version/bin/super"
  if [[ -n $version && -x $bin ]]; then printf '%s' "$bin"; else printf 'super'; fi
}

# prc_get <step> <branch> <forced-harness-or-empty>: what <step> runs with, as
# one JSON object. Later layers win; null removes the key: global harness block,
# branch harness block, global step block, branch step block. With no args in
# the files, git config pr-tend.<harness>.args supplies them.
prc_get() {
  local step=$1 forced=$3 query super hexpr gf bf gj bj out h gargs
  [[ $step =~ ^[a-z][a-z0-9-]*$ ]] || { prc_err "invalid step name: $step"; return; }
  hexpr='coalesce(b.steps[s].harness, g.steps[s].harness, b.harness, g.harness, d.harness)'
  if [[ -n $forced ]]; then
    [[ $forced =~ ^[a-z][a-z0-9-]*$ ]] || { prc_err "invalid harness name: $forced"; return; }
    hexpr='"'$forced'"'
  fi
  query='aggregate cfg:=collect(this)
    | values {g: cfg[0], b: cfg[1], d: cfg[2], s: "'$step'"}
    | values {g, b, s, h: '"$hexpr"'}
    | values {harness: h, ...coalesce(g.harnesses[h], {}), ...coalesce(b.harnesses[h], {}),
              ...coalesce(g.steps[s][h], {}), ...coalesce(b.steps[s][h], {})}
    | values flatten(this) | unnest this | where value is not null
    | aggregate kv:=collect(this) | values unflatten(kv)'
  super=$(prc_superdb_binary)
  gf=$(prc_global_file)
  bf=$(prc_branch_file "$2") || return
  gj=$(prc_layer "$gf") || return
  bj=$(prc_layer "$bf") || return
  out=$(printf '%s\n%s\n%s\n' "$gj" "$bj" "$PRC_DEFAULTS" | "$super" -j -c "$query" -) || return
  if ! jq -e 'has("args")' <<<"$out" >/dev/null; then
    h=$(jq -r .harness <<<"$out") || return
    if gargs=$(git config --get "pr-tend.$h.args"); then
      out=$(jq -c --arg a "$gargs" '. + {args: $a}' <<<"$out") || return
    fi
  fi
  echo "$out"
}

# prc_setting <key> <branch-or-empty> <no-branch: true|false>: one value from
# the "settings" blocks, one line per element for a list. Lookup: branch file,
# global file, git config pr-tend.<key>, built-in default. A null in a file
# skips git config and takes the default.
prc_setting() {
  local key=$1 cur=$2 nobranch=$3 gf g bf b='{}' state rc=0
  [[ $key =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || { prc_err "invalid setting key: $key"; return; }
  if [[ $nobranch == true ]]; then
    cur=
  elif [[ -z $cur ]]; then
    cur=$(git branch --show-current 2>/dev/null) || cur=
  fi
  gf=$(prc_global_file)
  g=$(prc_layer "$gf") || return
  if [[ -n $cur ]]; then
    bf=$(prc_branch_file "$cur") || return
    b=$(prc_layer "$bf") || return
  fi
  state=$(jq -nc --argjson g "$g" --argjson b "$b" --arg k "$key" '
    [$b, $g] | map(.settings // {} | select(has($k))) | .[0][$k] as $v
    | if length == 0 then "absent" elif $v == null then "null" else {v: $v} end') || return
  if [[ $state == '"absent"' ]]; then
    git config --get-all "pr-tend.$key" && return 0
    rc=$?
    (( rc == 1 )) || return "$rc"
  fi
  if [[ $state == '"absent"' || $state == '"null"' ]]; then
    state=$(jq -c --arg k "$key" '.settings | select(has($k)) | {v: .[$k]}' <<<"$PRC_DEFAULTS") || return
    [[ -n $state ]] || return 3
  fi
  jq -r '.v | if type == "array" then .[] | tostring else tostring end' <<<"$state"
}

# prc_target_file <global: true|false> <branch-or-empty>: the file set/unset write.
prc_target_file() {
  local b
  if [[ $1 == true ]]; then prc_global_file; return 0; fi
  b=$(prc_branch_arg "$2") || return
  git rev-parse -q --verify "refs/heads/$b" >/dev/null || { prc_err "no such branch: $b"; return; }
  prc_branch_file "$b"
}

# prc_edit <file> <path> <jq filter> [jq args...]: rewrite <file> through the
# filter, with $p bound to <path> as an array. Leaves the file alone on failure.
prc_edit() {
  local f=$1 path=$2 filter=$3 cur='{}' tmp
  shift 3
  [[ $path =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]] \
    || { prc_err "invalid path: '$path' (dotted names, e.g. harnesses.claude.model)"; return; }
  if [[ -e $f ]]; then cur=$(prc_layer "$f") || return; fi
  mkdir -p "$(dirname "$f")" || return
  tmp=$(mktemp "$f.XXXXXX") || return
  if ! jq --arg path "$path" "$@" '($path | split(".")) as $p | '"$filter" <<<"$cur" > "$tmp"; then
    rm -f "$tmp"
    prc_err "couldn't update $f at $path"
    return
  fi
  mv "$tmp" "$f"
}

prc_set() { # <file> <path> <value> <json: true|false>
  if [[ $4 == true ]]; then
    jq empty <<<"$3" 2>/dev/null || { prc_err "not valid JSON: $3"; return; }
    prc_edit "$1" "$2" 'setpath($p; $v)' --argjson v "$3"
  else
    prc_edit "$1" "$2" 'setpath($p; $v)' --arg v "$3"
  fi
}

prc_unset() { prc_edit "$1" "$2" 'delpaths([$p])'; } # <file> <path>

prc_init_global() { # <force>
  local dest
  dest=$(prc_global_file)
  [[ $1 == true || ! -e $dest ]] || { prc_err "$dest exists; --force overwrites it"; return; }
  mkdir -p "$(dirname "$dest")" || return
  jq . <<<"$PRC_SKELETON" > "$dest" || return
  echo "wrote $dest"
}

prc_init() { # <force> <branch>
  local force=$1 b=$2 src dest
  git rev-parse -q --verify "refs/heads/$b" >/dev/null || { prc_err "no such branch: $b"; return; }
  src=$(prc_global_file)
  [[ -e $src ]] || { prc_err "no global file at $src; run pr-config init --global first"; return; }
  dest=$(prc_branch_file "$b") || return
  [[ $force == true || ! -e $dest ]] || { prc_err "$dest exists; --force overwrites it"; return; }
  mkdir -p "$(dirname "$dest")" || return
  prc_layer "$src" >/dev/null || return
  cp "$src" "$dest"
}
