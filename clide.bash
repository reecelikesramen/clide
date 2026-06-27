# clide.bash — bash shim for clide (thin wrapper around clide-core.sh)
# Source from ~/.bashrc:  source /path/to/clide.bash
#
# NOTE: bash cannot push text into the input buffer like zsh's `print -z`. In suggest mode
# clide prints the command AND adds it to history, so you press ↑ to get it editable.
#
# Usage mirrors the zsh shim:
#   clide <prompt...>        auto-classify
#   clide -mh|-ms|-mo ...    model (default haiku, fast)
#   clide -E <level> ...     effort (default low)
#   clide -r | -s ...        force run | suggest
#   clide -i | -e | -y ...   inspect | explain | auto-yes
#   clide -1 | --once ...    stateless one-off (ignore tab memory)
#   clide -n | --new ...     fresh tab session, then run (bare -n resets)
#   clide code               elevate tab context into interactive claude
#   clide -h                 help
#   cmd 2>&1 | clide …       pipe context
#
# Memory: per terminal tab (keyed by shell PID), native claude --session-id/--resume,
# auto-rotated after 30 min idle or 10 turns, cleared on tab close.

_CLIDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_clide_sdir() { printf '%s' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/clide-sessions"; }
_clide_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null; }

# remove this tab's session file on shell exit (preserves an existing EXIT trap)
_clide_cleanup() { rm -f "$(_clide_sdir)/sess-$$" 2>/dev/null; }
trap _clide_cleanup EXIT

clide() {
  local _last_rc=$?

  local core="${CLIDE_CORE:-$_CLIDE_DIR/clide-core.sh}"
  [[ -r "$core" ]] || { printf 'clide: core not found at %s (set $CLIDE_CORE)\n' "$core" >&2; return 1; }

  local A D E OK CMD R
  if [[ -t 2 ]]; then
    A=$'\e[38;5;39m'; D=$'\e[38;5;244m'; E=$'\e[38;5;203m'
    OK=$'\e[38;5;78m'; CMD=$'\e[38;5;81m'; R=$'\e[0m'
  fi

  local sdir; sdir="$(_clide_sdir)"
  local sfile="$sdir/sess-$$"

  # ---- escalation: exactly `clide code` ----
  if [[ $# -eq 1 && "$1" == code ]]; then
    if [[ -r "$sfile" ]]; then
      local euuid; euuid=$(cut -d' ' -f1 "$sfile" 2>/dev/null)
      if [[ -n "$euuid" ]]; then
        printf '%s↗ elevating this tab into an interactive claude session…%s\n' "$A" "$R" >&2
        command claude --resume "$euuid"; return $?
      fi
    fi
    printf '%s✗%s %sclide:%s no context in this tab to elevate (run a clide command first)\n' "$E" "$R" "$D" "$R" >&2
    return 1
  fi

  # ---- flags ----
  local model="" effort="" force_mode="" inspect=0 explain=0 autoyes=0 once=0 newsess=0
  while [[ "$1" == -* ]]; do
    case "$1" in
      -mh) model=haiku;  shift ;;
      -ms) model=sonnet; shift ;;
      -mo) model=opus;   shift ;;
      -E)  effort="$2"; shift 2 ;;
      -r)  force_mode=run;     shift ;;
      -s)  force_mode=suggest; shift ;;
      -i)  inspect=1; shift ;;
      -e)  explain=1; shift ;;
      -y)  autoyes=1; shift ;;
      -1|--once) once=1; shift ;;
      -n|--new)  newsess=1; shift ;;
      -h|--help)
        printf '%sclide%s — turn a prompt into a shell command\n' "$A" "$R"
        printf '  %sclide <prompt>%s        auto: passive→suggest, active→run (confirm)\n' "$D" "$R"
        printf '  %s-mh|-ms|-mo%s           model haiku|sonnet|opus (default haiku, fast)\n' "$D" "$R"
        printf '  %s-E <level>%s            effort low|medium|high|xhigh|max (default low)\n' "$D" "$R"
        printf '  %s-r | -s%s               force run | suggest mode\n' "$D" "$R"
        printf '  %s-i%s                    read-only git inspection (→ sonnet/medium)\n' "$D" "$R"
        printf '  %s-e | -y%s               explain | auto-yes (destructive still gated)\n' "$D" "$R"
        printf '  %s-1 | --once%s           stateless one-off (ignore tab memory)\n' "$D" "$R"
        printf '  %s-n | --new%s            fresh tab session, then run (bare -n resets)\n' "$D" "$R"
        printf '  %sclide code%s            elevate tab context into interactive claude\n' "$D" "$R"
        printf '  %scmd 2>&1 | clide …%s    pipe output/errors in as context\n' "$D" "$R"
        printf '  %ssuggest mode%s: command added to history — press ↑ to edit & run\n' "$D" "$R"
        return 0 ;;
      --) shift; break ;;
      *)  printf '%s✗%s %sclide:%s unknown flag %s (try clide -h)\n' "$E" "$R" "$D" "$R" "$1" >&2; return 2 ;;
    esac
  done

  # bare `clide -n` → reset the tab session
  if [[ $newsess -eq 1 && -z "$*" ]]; then
    rm -f "$sfile" 2>/dev/null
    printf '%s↻%s %sclide: tab session reset%s\n' "$OK" "$R" "$D" "$R" >&2
    return 0
  fi

  local prompt="$*"
  [[ -n "$prompt" ]] || { printf '%s✗%s %sclide:%s no prompt (try clide -h)\n' "$E" "$R" "$D" "$R" >&2; return 2; }

  if (( inspect )); then
    [[ -z "$model"  ]] && model=sonnet
    [[ -z "$effort" ]] && effort=medium
  fi

  # ---- resolve tab session (uuid + mode) ----
  local sid="" sid_mode="off" turns=0
  if (( ! once )); then
    local now f_uuid="" f_turns=0 f_ts=0 stale=0
    now=$(date +%s)
    if [[ -r "$sfile" ]]; then
      f_uuid=$(cut -d' ' -f1 "$sfile"); f_turns=$(cut -d' ' -f2 "$sfile"); f_ts=$(cut -d' ' -f3 "$sfile")
    fi
    [[ -z "$f_uuid" ]] && stale=1
    [[ -n "$f_ts" ]] && (( now - f_ts > 1800 )) && stale=1
    [[ -n "$f_turns" ]] && (( f_turns >= 10 )) && stale=1
    if (( newsess || stale )); then
      sid=$(_clide_uuid); sid_mode=new; turns=0
    else
      sid=$f_uuid; sid_mode=resume; turns=$f_turns
    fi
  fi

  local last_cmd
  last_cmd="$(fc -ln -2 2>/dev/null | sed 's/^[[:space:]]*//' | grep -vE '^clide([[:space:]]|$)' | tail -1)"

  # carry forward a previously interrupted request (then clear it)
  local interrupted=""
  if [[ -r "$sfile.int" ]]; then interrupted="$(cat "$sfile.int" 2>/dev/null)"; rm -f "$sfile.int"; fi

  _clide_call() {
    CLIDE_PROMPT="$prompt" CLIDE_MODEL="$model" CLIDE_EFFORT="$effort" \
    CLIDE_FORCE_MODE="$force_mode" CLIDE_INSPECT="$inspect" CLIDE_EXPLAIN="$explain" \
    CLIDE_LAST_CMD="$last_cmd" CLIDE_LAST_RC="$_last_rc" CLIDE_INTERRUPTED="$interrupted" \
    CLIDE_SID="$sid" CLIDE_SID_MODE="$sid_mode" CLIDE_QUIET_ERR="$1" \
    command sh "$core"
  }

  local decision rc
  if [[ "$sid_mode" == resume ]]; then
    decision="$(_clide_call 1)"; rc=$?
  else
    decision="$(_clide_call 0)"; rc=$?
  fi
  if (( rc != 0 && rc != 130 )) && [[ "$sid_mode" == resume ]]; then
    sid=$(_clide_uuid); sid_mode=new; turns=0
    decision="$(_clide_call 0)"; rc=$?
  fi
  if (( rc == 130 )); then
    mkdir -p "$sdir" 2>/dev/null; printf '%s\n' "$prompt" > "$sfile.int"
    return 130
  fi
  (( rc != 0 )) && return $rc

  if (( ! once )) && [[ -n "$sid" ]]; then
    mkdir -p "$sdir" 2>/dev/null
    printf '%s %s %s\n' "$sid" "$(( turns + 1 ))" "$(date +%s)" > "$sfile"
  fi

  local mode cmd note explain_txt danger
  mode="$(printf '%s' "$decision"        | jq -r '.mode    // "error"' 2>/dev/null)"
  cmd="$(printf '%s' "$decision"         | jq -r '.cmd     // empty'   2>/dev/null)"
  note="$(printf '%s' "$decision"        | jq -r '.note    // empty'   2>/dev/null)"
  explain_txt="$(printf '%s' "$decision" | jq -r '.explain // empty'   2>/dev/null)"
  danger="$(printf '%s' "$decision"      | jq -r '.danger  // 0'       2>/dev/null)"

  case "$mode" in
    info)  return 0 ;;
    error) return 1 ;;
  esac
  [[ -n "$cmd" ]] || return 1

  [[ -n "$explain_txt" ]] && printf '%s» %s%s\n' "$D" "$explain_txt" "$R"
  [[ -n "$note"        ]] && printf '%s› %s%s\n' "$D" "$note" "$R"
  (( danger )) && printf '%s⚠ DESTRUCTIVE%s %s— review carefully%s\n' "$E" "$R" "$D" "$R"

  if [[ "$mode" == suggest ]]; then
    printf '%s$ %s%s\n' "$CMD" "$cmd" "$R"
    history -s "$cmd"
    printf '%s↳ in history — press ↑ to edit & run%s\n' "$OK" "$R" >&2
  else
    printf '%s$ %s%s\n' "$CMD" "$cmd" "$R"
    local ans=""
    if (( danger )); then
      printf "%stype 'yes' to run:%s " "$E" "$R"
      if [[ -t 0 ]]; then read -r ans; else read -r ans </dev/tty 2>/dev/null; fi
      if [[ "$ans" == "yes" ]]; then eval "$cmd"; else printf '%s✗ skipped%s\n' "$D" "$R"; fi
    elif (( autoyes )); then
      eval "$cmd"
    else
      printf '%srun this? [y/N]%s ' "$D" "$R"
      if [[ -t 0 ]]; then read -n1 -r ans; else read -n1 -r ans </dev/tty 2>/dev/null; fi
      printf '\n'
      if [[ "$ans" == [yY] ]]; then eval "$cmd"; else printf '%s✗ skipped%s\n' "$D" "$R"; fi
    fi
  fi
}
