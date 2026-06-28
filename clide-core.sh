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

# detect the target OS/shell so the model picks portable, platform-correct commands
os=$(uname -s 2>/dev/null)
case "$os" in
  Darwin) os_clause="Target OS: macOS (BSD userland). For in-place edits use \`sed -i ''\` (BSD sed); GNU-only flags are unavailable." ;;
  Linux)  os_clause="Target OS: Linux (GNU userland). For in-place edits use \`sed -i\` (GNU sed)." ;;
  *)      os_clause="Target OS: ${os:-unknown}." ;;
esac
[ -n "$CLIDE_SHELL" ] && os_clause="$os_clause Target shell: $CLIDE_SHELL."

SYS='You translate the user request into ONE shell command for their terminal. Producing a command is
your default and your job: treat almost every request as actionable, including playful ones
("tell a joke with echo" -> an echo command) and edits ("fix that line" -> a sed/printf/tee one-liner).
'"$elev_clause"'
'"$os_clause"'
You may receive a <context> block with the previous command, its exit code, and piped output/errors;
use it to resolve "that"/"this"/"the error" and to fix failures. Never echo secrets from context.
Your reply is validated against a JSON schema with fields: mode (run|suggest|info), cmd, answer, note.
Put the command in "cmd" (omit only when mode=info); put info-mode prose in "answer"; "note" is an
optional <=8 word why.
'"$explain_clause"'
Choose mode:
- "run" — you can produce a COMPLETE, unambiguous command AND the request is a directive to act
  (fix, delete, rebase, create, clean, restart, "do X for me"). clide runs it after a y/N confirm,
  so the command must be safe to execute verbatim.
- "suggest" — anything that isn'\''t a clear-cut run. Read-only inspection/listing (ls, find,
  git status/log/branch, ps, docker ps, df, du, grep) is exploratory and ALWAYS suggest, even when
  the command is complete. Also suggest when the command has placeholders / paths / names to fill in,
  or the args are ambiguous. It lands in their editable buffer and they press Enter. A request phrased
  as "what is the command to X" or "how do I X" still gets a command here — never info.
- "info" — ONLY when the request is a genuine knowledge / why / explanation question that has no
  command form (e.g. "why did the last 3 attempts fail when they looked fine?"). Put the prose in
  "answer" and omit "cmd". Do NOT fall back to info just because a request is casual, playful, or
  underspecified, and NOT for "what'\''s the command/how do I" questions — emit your best command instead.
cmd must be a runnable command line for the target shell above: no backtick fences, no leading $,
one line, safe/idempotent forms preferred.
If underspecified, still emit your single best-guess command (run or suggest) with the caveat in
"note" — never refuse, never ask questions, never apologize. Output nothing but the one JSON line.'

# ---- build claude args ----
# --json-schema enforces the reply shape at the claude level (StructuredOutput tool); the prose->info
# fallback below still covers the case where the model emits prose instead of a tool call.
SCHEMA='{"type":"object","properties":{"mode":{"type":"string","enum":["run","suggest","info"]},"cmd":{"type":"string"},"answer":{"type":"string"},"note":{"type":"string"},"explain":{"type":"string"}},"required":["mode"]}'
# --safe-mode: hermetic translation — no user CLAUDE.md / hooks / skills / MCP can leak in or skew it.
set -- -p "$full_prompt" --model "$model" --output-format text \
       --append-system-prompt "$SYS" --exclude-dynamic-system-prompt-sections \
       --safe-mode --json-schema "$SCHEMA" --max-budget-usd "${CLIDE_MAX_USD:-0.50}"
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
mode=$(printf '%s' "$json" | jq -r '.mode // "suggest"' 2>/dev/null)
cmd=$(printf '%s' "$json" | jq -r '.cmd // empty' 2>/dev/null)

if [ "$mode" = info ] || [ -z "$cmd" ]; then
  # informational answer (explicit info mode, or model went off-contract); shim no-ops
  answer=$(printf '%s' "$json" | jq -r '.answer // empty' 2>/dev/null)
  [ -n "$answer" ] || answer=$out
  printf '%sℹ%s %sanswer:%s\n' "$C_ACC" "$C_RST" "$C_DIM" "$C_RST" >&2
  printf '%s\n' "$answer" >&2
  printf '{"mode":"info"}\n'
  exit 0
fi

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
