# Harness and settings for the PR pipeline. Sourced by bin/pr-config, pr-act,
# pr-watch and pr-state; needs bash 5 and super 0.3.0. See docs/pr-workflow/design.md,
# "Config files".
#
# Every function returns 1 on an error (message on stderr) and never exits:
# callers run them as `x=$(prc_...) || die`, where errexit is off inside, so
# each step checks its own status. prc_get returns 3 for a path with no value
# and no default.
#
# super reads nothing from a here-string or a < redirect (super 0.3.0), so input
# is always piped.

PRC_DEFAULTS='{"harness": "claude",
  "settings": {"remote": "origin", "stepTimeout": 1800, "interval": 300, "replyPrefix": "🤖 ",
               "verify": "", "notify": "",
               "botLogin": [], "botIgnore": [], "botIgnoreBody": []}}'
PRC_SKELETON='{"harness": "claude", "harnesses": {"claude": {}, "pi": {}}, "steps": {}, "settings": {}}'

# A step is a pr-act verb that runs an agent: add new ones here. The global-only
# settings are the watcher's, which reads no branch file.
PRC_HARNESSES=(claude pi)
PRC_STEPS=(address ci-fix describe implement review)
PRC_GLOBAL_ONLY=(remote interval notify)
PRC_SETTINGS='stepTimeout?:uint64,replyPrefix?:string,verify?:string,
              botLogin?:[string],botIgnore?:[string],botIgnoreBody?:[string]'
PRC_TYPES='type hclaude = {model?:string,effort?:enum(low,medium,high,xhigh,max),args?:string}
type hpi = {provider?:string,model?:string,effort?:enum(off,minimal,low,medium,high,xhigh,max),args?:string}
type harness = enum(claude,pi)
type step = {harness?:harness,claude?:hclaude,pi?:hpi}
type steps = {'"$(printf '"%s"?:step,' "${PRC_STEPS[@]}" | sed 's/,$//')"'}
type branch_settings = {'"$PRC_SETTINGS"'}
type global_settings = {remote?:string,interval?:uint64,notify?:string,'"$PRC_SETTINGS"'}'

# One line per problem: a key the layer's type doesn't have, or a value that
# doesn't cast. cast drops unknown keys silently, hence the diff of the input's
# leaves against the cast's.
PRC_CHECK='fork
    ( unnest flatten(this) | values {k: join(key, "."), ok: false, err: ""} )
    ( unnest flatten(cast(this, <config>))
      | values {k: join(key, "."), ok: not is_error(value),
                err: is_error(value) ? f"{under(value).message}: {under(value).on}" : ""} )
| aggregate ok:=or(ok), errs:=collect(err) by k
| where not ok | sort k
| values {k, err: join(errs, "")}
| values err != "" ? f"{k}: {err}" : k in GLOBAL_ONLY_ ? f"{k}: global file only" : f"{k}: unknown key"'

# Deep merge of {i, v} layers: a leaf from a higher i replaces every leaf at,
# above or below its path in lower layers. Lists are leaves; nulls are kept.
# unflatten needs its keys grouped, hence the sort: keys come out alphabetical.
# No `unnest ... into`: its subquery panicked ("context canceled") in 12 of 200
# runs on super 0.3.0.
PRC_MERGE='unnest {i, kv: flatten(v)} | values {i, k: kv.key, v: kv.value} WHERE_
| aggregate es:=collect(this)
| unnest {es, e: es}
| unnest {e, f: es}
| values {e, s: f.i > e.i and (f.k == e.k[0:len(f.k)] or e.k == f.k[0:len(e.k)])}
| aggregate shadowed:=or(s) by e
| where not shadowed
| sort e.k
| aggregate kv:=collect({key: e.k, value: e.v})
| values unflatten(coalesce(kv, []))'

prc_err() { echo "pr-config: $*" >&2; return 1; }

prc_global_file() { echo "${PR_TEND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/pr-tend/config.json}"; }

prc_branch_file() { # <branch>
  local dir name=${1//[%]/%25}
  dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { prc_err "not a git repository"; return; }
  echo "$dir/pr-tend/${name//\//%2F}.json"
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

# Requires 0.3.0, the only version this has run on. Sets PRC_SUPER_BIN, so call
# it outside $( ); otherwise every prc_super call repeats the check.
prc_super_init() {
  local bin v
  bin=$(prc_superdb_binary)
  v=$("$bin" -version 2>/dev/null) || v=
  [[ -n $v ]] || { prc_err "needs super 0.3.0, but $bin didn't run"; return; }
  [[ $v == "Version: v0.3.0" ]] || { prc_err "needs super 0.3.0, but $bin is ${v#Version: }"; return; }
  PRC_SUPER_BIN=$bin
}

prc_super() {
  [[ -n ${PRC_SUPER_BIN:-} ]] || prc_super_init || return
  "$PRC_SUPER_BIN" "$@"
}

# prc_problems <global|branch> <name>: a layer's JSON on stdin; reports each
# problem as "<name>: <problem>" and returns 1 if there are any.
prc_problems() {
  local out line only
  only=$(printf '"settings.%s",' "${PRC_GLOBAL_ONLY[@]}")
  out=$(prc_super -i json -f line -c "$PRC_TYPES
    type config = {harness?:harness,harnesses?:{claude?:hclaude,pi?:hpi},steps?:steps,settings?:${1}_settings}
    ${PRC_CHECK/GLOBAL_ONLY_/[${only%,}]}" -) || { prc_err "couldn't check $2"; return; }
  [[ -n $out ]] || return 0
  while IFS= read -r line; do prc_err "$2: $line"; done <<<"$out"
  return 1
}

# prc_layer <file> [global|branch]: its JSON, or {} when it doesn't exist.
# Checked against that layer's type when one is named.
prc_layer() {
  local kinds
  [[ -e $1 ]] || { echo '{}'; return 0; }
  kinds=$(prc_super -i json -f line -c 'values kind(this)' "$1" 2>/dev/null) || kinds=
  [[ $kinds == record ]] || { prc_err "not a JSON object: $1"; return; }
  if [[ -n ${2:-} ]]; then cat "$1" | prc_problems "$2" "$1" || return; fi
  cat "$1"
}

# prc_path_expr <dotted.path>: this["a"]["b"]. The names are checked first, so
# they can't carry query syntax.
prc_path_expr() {
  local seg expr=this
  local -a segs
  [[ $1 =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]] \
    || { prc_err "invalid path: '$1' (dotted names, e.g. harnesses.claude.model)"; return; }
  IFS=. read -ra segs <<<"$1"
  for seg in "${segs[@]}"; do expr+="[\"$seg\"]"; done
  echo "$expr"
}

# prc_files <branch-or-empty> <no-branch: true|false>: the global file with the
# branch file merged over it, nulls kept. An empty <branch> means the current
# one, or none when detached or outside a repo; a named one needs a repo.
prc_files() {
  local b=$1 gf g bf bj='{}'
  if [[ $2 == true ]]; then
    b=
  elif [[ -z $b ]]; then
    b=$(git branch --show-current 2>/dev/null) || b=
  fi
  gf=$(prc_global_file)
  g=$(prc_layer "$gf" global) || return
  if [[ -n $b ]]; then
    bf=$(prc_branch_file "$b") || return
    bj=$(prc_layer "$bf" branch) || return
  fi
  printf '{"i":1,"v":%s}\n{"i":2,"v":%s}\n' "$g" "$bj" | prc_super -i json -j -c "${PRC_MERGE/WHERE_/}" -
}

# prc_paths <branch-or-empty> <no-branch: true|false>: "global  <path>" and
# "branch  <path>", with "  (missing)" after a file that doesn't exist.
prc_paths() {
  local b=$1 f why=
  prc_path_line global "$(prc_global_file)"
  [[ $2 != true ]] || return 0
  if [[ -z $b ]]; then
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      why="not a git repository"
    else
      b=$(git branch --show-current) || return
      [[ -n $b ]] || why="detached HEAD"
    fi
  fi
  if [[ -n $why ]]; then echo "branch  (none: $why)"; return 0; fi
  f=$(prc_branch_file "$b") || return
  prc_path_line branch "$f"
}

prc_path_line() { if [[ -e $2 ]]; then echo "$1  $2"; else echo "$1  $2  (missing)"; fi; }

# prc_get <path> <branch-or-empty> <no-branch: true|false> [json]: one value.
# A string prints raw, a list one element per line, an object as JSON; json
# prints any of them as JSON. A null in a file falls through to the built-in
# default.
prc_get() {
  local expr files kind q op=values
  local -a fmt=(-f line)
  expr=$(prc_path_expr "$1") || return
  files=$(prc_files "$2" "$3") || return
  q="${PRC_MERGE/WHERE_/| where v is not null}"
  kind=$(printf '{"i":0,"v":%s}\n{"i":1,"v":%s}\n' "$PRC_DEFAULTS" "$files" \
    | prc_super -i json -f line -c "$q | values is_error($expr) ? \"missing\" : kind($expr)" -) || return
  [[ $kind != missing ]] || return 3
  if [[ ${4:-} == json || $kind == record ]]; then
    fmt=(-j)
  elif [[ $kind == array ]]; then
    op=unnest
  fi
  printf '{"i":0,"v":%s}\n{"i":1,"v":%s}\n' "$PRC_DEFAULTS" "$files" | prc_super -i json "${fmt[@]}" -c "$q | $op $expr" -
}

# prc_show <branch-or-empty> <no-branch: true|false>: the whole merged config,
# defaults included, as pretty JSON.
prc_show() {
  local files
  files=$(prc_files "$1" "$2") || return
  printf '{"i":0,"v":%s}\n{"i":1,"v":%s}\n' "$PRC_DEFAULTS" "$files" \
    | prc_super -i json -J -c "${PRC_MERGE/WHERE_/| where v is not null}" -
}

# prc_step <step> <branch-or-empty> <forced-harness-or-empty>: what <step> runs
# with, as one JSON object: the step's harness block with the step's block for
# that harness over it. A null in the step block clears the harness block's key.
prc_step() {
  local step=$1 forced=$3 hexpr files
  [[ " ${PRC_STEPS[*]} " == *" $step "* ]] || { prc_err "unknown step: $step (${PRC_STEPS[*]})"; return; }
  hexpr="coalesce(f.steps[\"$step\"].harness, f.harness, d.harness)"
  if [[ -n $forced ]]; then
    [[ " ${PRC_HARNESSES[*]} " == *" $forced "* ]] || { prc_err "unknown harness: $forced (${PRC_HARNESSES[*]})"; return; }
    hexpr="\"$forced\""
  fi
  files=$(prc_files "$2" false) || return
  printf '%s\n%s\n' "$PRC_DEFAULTS" "$files" | prc_super -i json -j -c "
    aggregate c:=collect(this) | values {d: c[0], f: c[1]}
    | values {f, h: $hexpr}
    | values {harness: h, ...coalesce(f.harnesses[h], {}), ...coalesce(f.steps[\"$step\"][h], {})}
    | unnest flatten(this) | where value is not null
    | aggregate kv:=collect(this) | values unflatten(kv)" -
}

# prc_target_file <global: true|false> <branch-or-empty>: the file set/unset write.
prc_target_file() {
  local b
  if [[ $1 == true ]]; then prc_global_file; return 0; fi
  b=$(prc_branch_arg "$2") || return
  git rev-parse -q --verify "refs/heads/$b" >/dev/null || { prc_err "no such branch: $b"; return; }
  prc_branch_file "$b"
}

prc_json_string() { # <string>
  local s=$1 t=${1//[$'\n\t\r']/}
  [[ ! $t =~ [[:cntrl:]] ]] || { prc_err "control characters aren't supported in a value"; return; }
  s=${s//\\/\\\\} s=${s//\"/\\\"} s=${s//$'\n'/\\n} s=${s//$'\t'/\\t} s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

# prc_write <file> <super query over {doc, v}> <value-json>: rewrite <file>
# through the query. Leaves the file alone on failure.
prc_write() {
  local f=$1 cur='{}' tmp layer=branch
  [[ $f != "$(prc_global_file)" ]] || layer=global
  if [[ -e $f ]]; then cur=$(prc_layer "$f") || return; fi
  mkdir -p "$(dirname "$f")" || return
  tmp=$(mktemp "$f.XXXXXX") || return
  if ! printf '{"doc":%s,"v":%s}\n' "$cur" "$3" | prc_super -i json -J -c "$2" - > "$tmp"; then
    rm -f "$tmp"
    prc_err "couldn't update $f"
    return
  fi
  cat "$tmp" | prc_problems "$layer" "$f" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}

prc_set() { # <file> <path> <value> <json: true|false>
  local expr vj kinds parent=this seg ok=true cur
  local -a segs
  expr=$(prc_path_expr "$2") || return
  if [[ $4 == true ]]; then
    kinds=$(printf '%s' "$3" | prc_super -i json -f line -c 'values kind(this)' - 2>/dev/null) || kinds=
    [[ -n $kinds && $kinds != *$'\n'* ]] || { prc_err "not one JSON value: $3"; return; }
    vj=$3
  else
    vj=$(prc_json_string "$3") || return
  fi
  IFS=. read -ra segs <<<"$2"
  for seg in "${segs[@]:0:${#segs[@]}-1}"; do
    parent+="[\"$seg\"]"
    ok+=" and (is_error($parent) or $parent is null or kind($parent) == \"record\")"
  done
  cur=$(prc_layer "$1") || return
  ok=$(printf '%s\n' "$cur" | prc_super -i json -f line -c "values $ok" -) || return
  [[ $ok == true ]] || { prc_err "couldn't set $2 in $1: a parent isn't an object"; return; }
  prc_write "$1" "put this[\"doc\"]${expr#this}:=v | values doc" "$vj"
}

prc_unset() { # <file> <path>
  local expr
  expr=$(prc_path_expr "$2") || return
  prc_write "$1" "drop this[\"doc\"]${expr#this} | values doc" null
}

prc_init_global() { # <force>
  local dest
  dest=$(prc_global_file)
  [[ $1 == true || ! -e $dest ]] || { prc_err "$dest exists; --force overwrites it"; return; }
  mkdir -p "$(dirname "$dest")" || return
  printf '%s\n' "$PRC_SKELETON" | prc_super -i json -J -c 'values this' - > "$dest" || return
  echo "wrote $dest"
}

# prc_init <force> <branch>: a branch file of empty blocks; it holds only overrides.
prc_init() {
  local force=$1 b=$2 dest
  git rev-parse -q --verify "refs/heads/$b" >/dev/null || { prc_err "no such branch: $b"; return; }
  dest=$(prc_branch_file "$b") || return
  [[ $force == true || ! -e $dest ]] || { prc_err "$dest exists; --force overwrites it"; return; }
  mkdir -p "$(dirname "$dest")" || return
  printf '%s\n' "$PRC_SKELETON" | prc_super -i json -J -c 'drop harness' - > "$dest" || return
  echo "wrote $dest"
}
