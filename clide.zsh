# clide.zsh — zsh shim for clide (thin wrapper around clide-core.sh)
# Source from ~/.zshrc:  source /path/to/clide.zsh
#
# Usage:
#   clide <prompt...>        auto-classify: passive→suggest (inject), active→run (confirm)
#   clide -mh|-ms|-mo ...    model haiku | sonnet | opus  (default haiku, fast)
#   clide -E <level> ...     effort low|medium|high|xhigh|max (default low)
#   clide -r | -s ...        force run | suggest mode
#   clide -i ...             allow read-only git inspection (bumps to sonnet/medium)
#   clide -e ...             include a one-line explanation
#   clide -y ...             auto-yes in run mode (destructive still gated)
#   clide -1 | --once ...    stateless one-off (ignore tab memory)
#   clide -n | --new ...     start a fresh tab session, then run (bare -n just resets)
#   clide code               elevate this tab's context into an interactive claude session
#   clide -h                 help
#   cmd 2>&1 | clide …       pipe output/errors in as context
#
# Memory: each terminal tab keeps a conversation (native claude --session-id/--resume),
# keyed by the shell PID, auto-rotated after 30 min idle or 10 turns, cleared on tab close.

_CLIDE_DIR=${${(%):-%x}:A:h}
_clide_sdir() { print -r -- "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/clide-sessions" }
_clide_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null }

# remove this tab's session file when the shell exits
autoload -Uz add-zsh-hook 2>/dev/null
_clide_zshexit() { rm -f "$(_clide_sdir)/sess-$$" 2>/dev/null }
add-zsh-hook zshexit _clide_zshexit 2>/dev/null

clide() {
  local _last_rc=$?
  emulate -L zsh
  setopt local_options no_nomatch no_monitor no_notify

  local core=${CLIDE_CORE:-$_CLIDE_DIR/clide-core.sh}
  [[ -r "$core" ]] || { print -u2 -- "clide: core not found at $core (set \$CLIDE_CORE)"; return 1 }

  local A D E OK CMD R
  if [[ -t 2 ]]; then
    A=$'\e[38;5;39m'; D=$'\e[38;5;244m'; E=$'\e[38;5;203m'
    OK=$'\e[38;5;78m'; CMD=$'\e[38;5;81m'; R=$'\e[0m'
  fi

  local sdir="$(_clide_sdir)" sfile="$(_clide_sdir)/sess-$$"

  # ---- escalation: exactly `clide code` ----
  if (( $# == 1 )) && [[ "$1" == code ]]; then
    if [[ -r "$sfile" ]]; then
      local euuid; euuid=$(cut -d' ' -f1 "$sfile" 2>/dev/null)
      if [[ -n "$euuid" ]]; then
        print -u2 -- "${A}↗ elevating this tab into an interactive claude session…${R}"
        command claude --resume "$euuid"
        return $?
      fi
    fi
    print -u2 -- "${E}✗${R} ${D}clide:${R} no context in this tab to elevate (run a clide command first)"
    return 1
  fi

  # ---- flags ----
  local model="" effort="" force_mode="" inspect=0 explain=0 autoyes=0 once=0 newsess=0
  while [[ "$1" == -* ]]; do
    case "$1" in
      -mh) model=haiku;  shift ;;
      -ms) model=sonnet; shift ;;
      -mo) model=opus;   shift ;;
      -E)  effort=$2; shift 2 ;;
      -r)  force_mode=run;     shift ;;
      -s)  force_mode=suggest; shift ;;
      -i)  inspect=1; shift ;;
      -e)  explain=1; shift ;;
      -y)  autoyes=1; shift ;;
      -1|--once) once=1; shift ;;
      -n|--new)  newsess=1; shift ;;
      -h|--help)
        print -- "${A}clide${R} — turn a prompt into a shell command"
        print -- "  ${D}clide <prompt>${R}        auto: passive→suggest (inject), active→run (confirm)"
        print -- "  ${D}-mh|-ms|-mo${R}           model haiku|sonnet|opus (default haiku, fast)"
        print -- "  ${D}-E <level>${R}            effort low|medium|high|xhigh|max (default low)"
        print -- "  ${D}-r | -s${R}               force run | suggest mode"
        print -- "  ${D}-i${R}                    read-only git inspection (→ sonnet/medium)"
        print -- "  ${D}-e${R}                    add a one-line explanation"
        print -- "  ${D}-y${R}                    auto-yes in run mode (destructive still gated)"
        print -- "  ${D}-1 | --once${R}           stateless one-off (ignore tab memory)"
        print -- "  ${D}-n | --new${R}            fresh tab session, then run (bare -n resets)"
        print -- "  ${D}clide code${R}            elevate tab context into interactive claude"
        print -- "  ${D}cmd 2>&1 | clide …${R}    pipe output/errors in as context"
        return 0 ;;
      --) shift; break ;;
      *)  print -u2 -- "${E}✗${R} ${D}clide:${R} unknown flag $1 (try clide -h)"; return 2 ;;
    esac
  done

  # bare `clide -n` → just reset the tab session
  if (( newsess )) && [[ -z "$*" ]]; then
    rm -f "$sfile" 2>/dev/null
    print -u2 -- "${OK}↻${R} ${D}clide: tab session reset${R}"
    return 0
  fi

  local prompt="$*"
  [[ -n "$prompt" ]] || { print -u2 -- "${E}✗${R} ${D}clide:${R} no prompt (try clide -h)"; return 2 }

  if (( inspect )); then
    [[ -z "$model"  ]] && model=sonnet
    [[ -z "$effort" ]] && effort=medium
  fi

  # ---- resolve tab session (uuid + mode) ----
  local sid="" sid_mode="off" turns=0
  if (( ! once )); then
    local now; now=$(date +%s)
    local f_uuid="" f_turns=0 f_ts=0
    if [[ -r "$sfile" ]]; then
      f_uuid=$(cut -d' ' -f1 "$sfile"); f_turns=$(cut -d' ' -f2 "$sfile"); f_ts=$(cut -d' ' -f3 "$sfile")
    fi
    local stale=0
    [[ -z "$f_uuid" ]] && stale=1
    [[ -n "$f_ts" ]] && (( now - f_ts > 1800 )) && stale=1   # 30 min idle
    [[ -n "$f_turns" ]] && (( f_turns >= 10 )) && stale=1     # turn cap
    if (( newsess || stale )); then
      sid=$(_clide_uuid); sid_mode=new; turns=0
    else
      sid=$f_uuid; sid_mode=resume; turns=$f_turns
    fi
  fi

  # ---- previous shell command (drop clide itself) ----
  local last_cmd
  last_cmd="$(fc -ln -2 2>/dev/null | sed 's/^[[:space:]]*//' | grep -vE '^clide([[:space:]]|$)' | tail -1)"

  # ---- carry forward a previously interrupted request (then clear it) ----
  local interrupted=""
  if [[ -r "$sfile.int" ]]; then interrupted="$(cat "$sfile.int" 2>/dev/null)"; rm -f "$sfile.int"; fi

  _clide_call() {
    CLIDE_PROMPT="$prompt" CLIDE_MODEL="$model" CLIDE_EFFORT="$effort" \
    CLIDE_FORCE_MODE="$force_mode" CLIDE_INSPECT="$inspect" CLIDE_EXPLAIN="$explain" \
    CLIDE_LAST_CMD="$last_cmd" CLIDE_LAST_RC="$_last_rc" CLIDE_INTERRUPTED="$interrupted" \
    CLIDE_SID="$sid" CLIDE_SID_MODE="$sid_mode" CLIDE_QUIET_ERR="$1" \
    command sh "$core"
  }

  # on a resume attempt, suppress the error line so a lost session recovers quietly
  local decision rc
  if [[ "$sid_mode" == resume ]]; then
    decision="$(_clide_call 1)"; rc=$?
  else
    decision="$(_clide_call 0)"; rc=$?
  fi

  # resume failed (session lost?) → rotate to a fresh session and retry once (not on cancel)
  if (( rc != 0 && rc != 130 )) && [[ "$sid_mode" == resume ]]; then
    sid=$(_clide_uuid); sid_mode=new; turns=0
    decision="$(_clide_call 0)"; rc=$?
  fi

  # cancelled (Esc/Ctrl-C) → remember it as context for the next call
  if (( rc == 130 )); then
    mkdir -p "$sdir" 2>/dev/null; print -r -- "$prompt" > "$sfile.int"
    return 130
  fi
  (( rc != 0 )) && return $rc

  # persist tab session (unless stateless)
  if (( ! once )) && [[ -n "$sid" ]]; then
    mkdir -p "$sdir" 2>/dev/null
    print -r -- "$sid $(( turns + 1 )) $(date +%s)" > "$sfile"
  fi

  local mode cmd note explain_txt danger
  mode="$(print -r -- "$decision"        | jq -r '.mode    // "error"' 2>/dev/null)"
  cmd="$(print -r -- "$decision"         | jq -r '.cmd     // empty'   2>/dev/null)"
  note="$(print -r -- "$decision"        | jq -r '.note    // empty'   2>/dev/null)"
  explain_txt="$(print -r -- "$decision" | jq -r '.explain // empty'   2>/dev/null)"
  danger="$(print -r -- "$decision"      | jq -r '.danger  // 0'       2>/dev/null)"

  case "$mode" in
    info)  return 0 ;;
    error) return 1 ;;
  esac
  [[ -n "$cmd" ]] || return 1

  [[ -n "$explain_txt" ]] && print -- "${D}» ${explain_txt}${R}"
  [[ -n "$note"        ]] && print -- "${D}› ${note}${R}"
  (( danger )) && print -- "${E}⚠ DESTRUCTIVE${R} ${D}— review carefully${R}"

  if [[ "$mode" == suggest ]]; then
    print -u2 -- "${OK}↳${R} ${D}ready — edit & press Enter${R}"
    print -z -- "$cmd"
  else
    print -- "${CMD}\$ ${cmd}${R}"
    local ans=""
    if (( danger )); then
      print -n -- "${E}type 'yes' to run:${R} "
      if [[ -t 0 ]]; then read -r ans; else read -r ans </dev/tty 2>/dev/null; fi
      [[ "$ans" == "yes" ]] && eval "$cmd" || print -- "${D}✗ skipped${R}"
    elif (( autoyes )); then
      eval "$cmd"
    else
      if [[ -t 0 ]]; then read -q "ans?${D}run this? [y/N]${R} "
      else read -q "ans?${D}run this? [y/N]${R} " </dev/tty 2>/dev/null; fi
      print
      [[ "$ans" == [yY] ]] && eval "$cmd" || print -- "${D}✗ skipped${R}"
    fi
  fi
}
