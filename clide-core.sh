#!/bin/sh
# clide-core.sh — POSIX core shared by the zsh and bash shims.
# Not meant to be called directly; the shell shims invoke it.
#
# Inputs (environment):
#   CLIDE_PROMPT      required — the user request
#   CLIDE_MODEL       model alias (default haiku)
#   CLIDE_EFFORT      effort level (default low; empty string = omit flag)
#   CLIDE_FORCE_MODE  "run" | "suggest" | "" (override the classifier)
#   CLIDE_INSPECT     "1" to allow read-only git inspection
#   CLIDE_EXPLAIN     "1" to request an explanation field
#   CLIDE_LAST_CMD    previous shell command (for context)
#   CLIDE_LAST_RC     previous command exit code
#   stdin             if piped (not a tty), included as terminal output context
#
# Output:
#   stdout — ONE compact JSON line for the shim:
#            {"mode":"run|suggest|info|error","cmd":"…","note":"…","explain":"…","danger":0|1}
#   stderr — spinner, the info/prose answer, and error messages (already styled)
#
# Exit: 0 on a usable decision (incl. info), non-zero on hard failure.

# ---- styling (stderr only; no-op when stderr isn't a tty) ----
if [ -t 2 ]; then
  C_ACC=$(printf '\033[38;5;174m'); C_DIM=$(printf '\033[38;5;244m')
  C_ERR=$(printf '\033[38;5;203m'); C_RST=$(printf '\033[0m')
else
  C_ACC=; C_DIM=; C_ERR=; C_RST=
fi

err() { [ "${CLIDE_QUIET_ERR:-0}" = 1 ] && return 0; printf '%s✗%s %sclide:%s %s\n' "$C_ERR" "$C_RST" "$C_DIM" "$C_RST" "$*" >&2; }

# ---- redaction: strip obvious secrets before anything leaves the machine ----
redact() {
  perl -pe '
    s/((?:token|secret|passwd|password|api[_-]?key|access[_-]?key|bearer|authorization)\s*[=:]\s*)\S+/${1}***/gi;
    s/(\w+:\/\/[^:\/\s]+:)[^@\s]+(@)/${1}***${2}/g;
    s/AKIA[0-9A-Z]{16}/AKIA****************/g;
    s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/***JWT***/g;
  ' 2>/dev/null
}

[ -n "$CLIDE_PROMPT" ] || { err "no prompt"; printf '{"mode":"error"}\n'; exit 2; }

model=${CLIDE_MODEL:-haiku}
# effort: default low, but an explicit empty CLIDE_EFFORT means "omit"
if [ -n "${CLIDE_EFFORT+set}" ]; then effort=$CLIDE_EFFORT; else effort=low; fi

# ---- gather context ----
piped=
if [ ! -t 0 ]; then
  piped=$(cat | tail -n 200 | redact)
fi
last_cmd=
[ -n "$CLIDE_LAST_CMD" ] && last_cmd=$(printf '%s' "$CLIDE_LAST_CMD" | redact)

ctx=
[ -n "$last_cmd" ] && ctx="Previous command (exit ${CLIDE_LAST_RC:-?}): ${last_cmd}
"
[ -n "$piped" ] && ctx="${ctx}Piped terminal output:
${piped}
"
if [ -n "$CLIDE_INTERRUPTED" ]; then
  ictx=$(printf '%s' "$CLIDE_INTERRUPTED" | redact)
  ctx="${ctx}Note: the user interrupted (cancelled) this earlier request before you answered: ${ictx}
"
fi
full_prompt=$CLIDE_PROMPT
[ -n "$ctx" ] && full_prompt="<context>
${ctx}</context>

Request: ${CLIDE_PROMPT}"

# ---- system prompt (the classifier + output contract) ----
explain_clause=
[ "$CLIDE_EXPLAIN" = 1 ] && explain_clause='Also include an "explain" field: one short sentence on what the command does.'

# detect an elevation helper so the model elevates instead of refusing
elev=
command -v sudo >/dev/null 2>&1 && elev=sudo
[ -z "$elev" ] && command -v doas >/dev/null 2>&1 && elev=doas
elev_clause=
[ -n "$elev" ] && elev_clause="\`$elev\` is available for elevation. For any command needing root/admin, prefix it with \`$elev \` (e.g. \`$elev systemctl restart nginx\`). NEVER claim you cannot elevate or run privileged commands — emit the $elev-prefixed command."

SYS='You translate a user request into ONE shell command for their terminal.
'"$elev_clause"'
You may receive a <context> block with the previous command, its exit code, and piped output/errors;
use it to resolve "that"/"this"/"the error" and to fix failures. Never echo secrets from context.
Output EXACTLY one line of compact JSON and nothing else (no markdown, no fences, no prose):
{"mode":"run|suggest","cmd":"<single shell command or one-liner>","note":"<<=8 word why, optional>"}
'"$explain_clause"'
Classify mode:
- "run" when the request is imperative / "do it for me" / fix / rebase / delete / create / clean.
- "suggest" when informational: "what is the command", "how do I", explain.
- When unsure, choose "suggest".
cmd must be a runnable POSIX/zsh command line, no backtick fences, no leading $.
Keep it to a single line. Prefer safe, idempotent forms when reasonable.
ALWAYS return the JSON object, even with incomplete information. NEVER reply with prose, questions,
apologies, or explanations outside the JSON. If underspecified, emit your single best-guess command
and put the caveat in "note". Output nothing but the one JSON line.'

# ---- build claude args ----
set -- -p "$full_prompt" --model "$model" --output-format text \
       --append-system-prompt "$SYS" --exclude-dynamic-system-prompt-sections
[ -n "$effort" ] && set -- "$@" --effort "$effort"
case "${CLIDE_SID_MODE:-off}" in
  new)    [ -n "$CLIDE_SID" ] && set -- "$@" --session-id "$CLIDE_SID" ;;
  resume) [ -n "$CLIDE_SID" ] && set -- "$@" --resume "$CLIDE_SID" ;;
esac
if [ "$CLIDE_INSPECT" = 1 ]; then
  set -- "$@" --allowedTools "Bash(git status:*) Bash(git log:*) Bash(git branch:*) Bash(git remote:*)" \
              --permission-mode acceptEdits
else
  set -- "$@" --disallowedTools "Bash Edit Write"
fi

# ---- call claude, with a spinner while it thinks (Esc or Ctrl-C cancels) ----
tmp=$(mktemp 2>/dev/null) || tmp=$(mktemp -t clide) || { err "mktemp failed"; printf '{"mode":"error"}\n'; exit 1; }
ESC=$(printf '\033')
stty_save=; cursor_hidden=0; cancelled=0
_cleanup() {
  [ -n "$stty_save" ] && stty "$stty_save" </dev/tty 2>/dev/null
  [ "$cursor_hidden" = 1 ] && printf '\033[?25h' >&2
  rm -f "$tmp" 2>/dev/null
}
trap _cleanup EXIT

if [ -t 2 ]; then
  have_tty=0
  if [ -r /dev/tty ]; then
    stty_save=$(stty -g </dev/tty 2>/dev/null) && { stty -icanon -echo min 0 time 1 </dev/tty 2>/dev/null && have_tty=1; }
  fi
  printf '\033[?25l' >&2; cursor_hidden=1
  claude "$@" </dev/null >"$tmp" 2>/dev/null &
  cpid=$!
  trap 'cancelled=1; kill $cpid 2>/dev/null' INT
  i=1
  while kill -0 "$cpid" 2>/dev/null; do
    set -- · ✻ ✽ ✶ ✳ ✢
    eval "f=\${$i}"
    printf '\r%s%s%s %sthinking · %s  %s(esc cancels)%s' "$C_ACC" "$f" "$C_RST" "$C_DIM" "$model" "$C_DIM" "$C_RST" >&2
    i=$((i % $# + 1))
    if [ "$have_tty" = 1 ]; then
      key=$(dd bs=1 count=1 2>/dev/null </dev/tty)   # ~0.1s timed read (min 0 time 1)
      [ "$key" = "$ESC" ] && { cancelled=1; kill $cpid 2>/dev/null; break; }
    else
      sleep 0.08
    fi
  done
  trap 'rm -f "$tmp"' INT
  [ -n "$stty_save" ] && { stty "$stty_save" </dev/tty 2>/dev/null; stty_save=; }
  printf '\r\033[K\033[?25h' >&2; cursor_hidden=0
  wait "$cpid" 2>/dev/null; rc=$?
else
  claude "$@" </dev/null >"$tmp" 2>/dev/null
  rc=$?
fi

if [ "$cancelled" = 1 ]; then
  printf '%s✗ interrupted%s\n' "$C_DIM" "$C_RST" >&2
  printf '{"mode":"cancelled"}\n'
  exit 130
fi

out=$(cat "$tmp")

if [ "$rc" -ne 0 ]; then
  err "claude exited $rc"
  [ -n "$out" ] && [ "${CLIDE_QUIET_ERR:-0}" != 1 ] && printf '%s%s%s\n' "$C_DIM" "$out" "$C_RST" >&2
  printf '{"mode":"error"}\n'
  exit "$rc"
fi

# ---- parse the model's JSON (grab first {...}, tolerate stray text) ----
json=$(printf '%s' "$out" | sed -n 's/^[^{]*\({.*}\)[^}]*$/\1/p' | head -1)
[ -n "$json" ] || json=$out
cmd=$(printf '%s' "$json" | jq -r '.cmd // empty' 2>/dev/null)

if [ -z "$cmd" ]; then
  # claude answered in prose — show it as an informational answer; shim no-ops
  printf '%sℹ%s %sno command — answer:%s\n' "$C_ACC" "$C_RST" "$C_DIM" "$C_RST" >&2
  printf '%s\n' "$out" >&2
  printf '{"mode":"info"}\n'
  exit 0
fi

mode=$(printf '%s' "$json" | jq -r '.mode // "suggest"' 2>/dev/null)
note=$(printf '%s' "$json" | jq -r '.note // empty' 2>/dev/null)
explain=$(printf '%s' "$json" | jq -r '.explain // empty' 2>/dev/null)
[ -n "$CLIDE_FORCE_MODE" ] && mode=$CLIDE_FORCE_MODE
[ "$mode" = run ] || mode=suggest

# ---- destructive-command detection ----
danger=0
case "$cmd" in
  *"rm -rf"*|*"rm -fr"*|*"rm -r -f"*|*" dd "*|*"mkfs"*|*":(){"*|\
  *"> /dev/sd"*|*"of=/dev/"*|*"chmod -R 777"*|*"shred "*|*"truncate "*|\
  *"git clean -f"*|*"git reset --hard"*|*"git reset"*"--hard"*)
    danger=1 ;;
esac
case "$cmd" in
  *"git push"*"--force"*|*"git push"*" -f"*) danger=1 ;;
esac

# ---- emit decision (jq builds valid JSON regardless of contents) ----
jq -nc --arg mode "$mode" --arg cmd "$cmd" --arg note "$note" \
       --arg explain "$explain" --argjson danger "$danger" \
       '{mode:$mode,cmd:$cmd,note:$note,explain:$explain,danger:$danger}'
