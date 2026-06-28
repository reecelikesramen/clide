#!/bin/sh
# eval/run.sh — offline scorer for clide's classifier + system prompt.
#
# Runs each case in eval/cases.jsonl against the real clide-core.sh and checks the
# emitted decision (mode + cmd + optional answer length) against expectations.
# Defaults to the shipped haiku + --effort low, since that's what most clide calls use.
#
# Loop: edit the SYS prompt in clide-core.sh, run this, watch the aggregate score.
#
# Case fields (one JSON object per line):
#   prompt      the user request
#   mode        expected mode regex, e.g. "run|suggest" or "info"
#   cmd_re      regex the emitted cmd must match
#   forbid_re   regex the emitted cmd must NOT match
#   answer_max  max words allowed in an info answer (excludes header + ↗ hint line)
#   last_cmd    previous-command context
#   piped       piped terminal-output context
#   turns       array of {prompt,mode,cmd_re,forbid_re,answer_max} run in ONE resumed
#               session, in order — reproduces multi-turn drift. Needs --multiturn.
#
# Usage:
#   sh eval/run.sh [--model haiku] [--effort low] [--runs 3] [--cases file] [--min 0.8] [--multiturn]
# Env equivalents: CLIDE_EVAL_MODEL CLIDE_EVAL_EFFORT CLIDE_EVAL_RUNS CLIDE_EVAL_MIN
#
# Exit: 0 if aggregate score >= min, non-zero otherwise (so it can gate a change).
set -u

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core=${CLIDE_CORE:-$dir/../clide-core.sh}
cases=$dir/cases.jsonl
model=${CLIDE_EVAL_MODEL:-haiku}
effort=${CLIDE_EVAL_EFFORT:-low}
runs=${CLIDE_EVAL_RUNS:-3}
min=${CLIDE_EVAL_MIN:-0.8}
multiturn=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model)     model=$2;  shift 2 ;;
    --effort)    effort=$2; shift 2 ;;
    --runs)      runs=$2;   shift 2 ;;
    --cases)     cases=$2;  shift 2 ;;
    --min)       min=$2;    shift 2 ;;
    --multiturn) multiturn=1; shift ;;
    -h|--help)
      printf 'usage: run.sh [--model m] [--effort e] [--runs n] [--cases f] [--min r] [--multiturn]\n'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "eval: need jq" >&2; exit 1; }
[ -r "$core" ]  || { echo "eval: core not found: $core" >&2; exit 1; }
[ -r "$cases" ] || { echo "eval: cases not found: $cases" >&2; exit 1; }

if [ -t 1 ]; then
  G=$(printf '\033[32m'); RED=$(printf '\033[31m'); Y=$(printf '\033[33m')
  DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
else
  G=; RED=; Y=; DIM=; RST=
fi

ANSF=$(mktemp 2>/dev/null) || ANSF=$(mktemp -t clideeval) || { echo "eval: mktemp failed" >&2; exit 1; }
trap 'rm -f "$ANSF"' EXIT

# fresh uuid for a multi-turn session (claude --session-id rejects reuse, so one per run)
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; return; fi
  [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
  h=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$h" ] || return 1
  printf '%s-%s-%s-%s-%s\n' \
    "$(printf %s "$h" | cut -c1-8)"  "$(printf %s "$h" | cut -c9-12)" \
    "$(printf %s "$h" | cut -c13-16)" "$(printf %s "$h" | cut -c17-20)" \
    "$(printf %s "$h" | cut -c21-32)"
}

# run clide-core once. inputs via globals: prompt model effort last_cmd piped sidmode sid.
# stdout = decision JSON; stderr (info answer) captured to $ANSF.
run_core() {
  if [ -n "$piped" ]; then
    printf '%s' "$piped" | CLIDE_PROMPT="$prompt" CLIDE_MODEL="$model" CLIDE_EFFORT="$effort" \
      CLIDE_LAST_CMD="$last_cmd" CLIDE_SID="$sid" CLIDE_SID_MODE="$sidmode" \
      CLIDE_QUIET_ERR=1 CLIDE_SHELL=sh sh "$core" 2>"$ANSF"
  else
    CLIDE_PROMPT="$prompt" CLIDE_MODEL="$model" CLIDE_EFFORT="$effort" \
      CLIDE_LAST_CMD="$last_cmd" CLIDE_SID="$sid" CLIDE_SID_MODE="$sidmode" \
      CLIDE_QUIET_ERR=1 CLIDE_SHELL=sh sh "$core" </dev/null 2>"$ANSF"
  fi
}

# score one turn. inputs via globals: prompt exp_mode cmd_re forbid_re answer_max
# last_cmd piped sidmode sid. sets: ok (0|1), tdetail.
score_turn() {
  decision=$(run_core)
  amode=$(printf '%s' "$decision" | jq -r '.mode // "error"' 2>/dev/null)
  acmd=$(printf '%s' "$decision"  | jq -r '.cmd  // empty'   2>/dev/null)
  ok=1
  [ -n "$exp_mode" ]  && { printf '%s' "$amode" | grep -qE "^($exp_mode)\$" || ok=0; }
  [ -n "$cmd_re" ]    && { printf '%s' "$acmd"  | grep -qE "$cmd_re"        || ok=0; }
  [ -n "$forbid_re" ] && { printf '%s' "$acmd"  | grep -qE "$forbid_re"     && ok=0; }
  awords=0
  if [ -n "$answer_max" ]; then
    # answer = stderr minus the "ℹ answer:" header line and any trailing ↗ hint line
    awords=$(sed '1d' "$ANSF" | grep -v '↗' | wc -w | tr -d ' ')
    [ "${awords:-0}" -le "$answer_max" ] || ok=0
  fi
  tdetail="$amode${acmd:+: $acmd}${answer_max:+ [${awords}w/${answer_max}]}"
}

total=0; passed=0
printf '%sclide eval — model=%s effort=%s runs=%s multiturn=%s%s\n\n' \
  "$DIM" "$model" "$effort" "$runs" "$multiturn" "$RST"

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac

  is_multi=$(printf '%s' "$line" | jq -r 'if .turns then "1" else "0" end')

  # -------- multi-turn case: replay turns in one resumed session --------
  if [ "$is_multi" = 1 ]; then
    [ "$multiturn" = 1 ] || continue   # skipped unless --multiturn
    nturns=$(printf '%s' "$line" | jq '.turns | length')
    label=$(printf '%s' "$line" | jq -r '.desc // (.turns[-1].prompt)')

    cpass=0; detail=; i=0
    while [ "$i" -lt "$runs" ]; do
      i=$((i + 1))
      sid=$(gen_uuid) || { echo "eval: cannot generate uuid; multi-turn unsupported here" >&2; break; }
      run_ok=1; seqdetail=; ti=0
      while [ "$ti" -lt "$nturns" ]; do
        prompt=$(printf '%s'    "$line" | jq -r ".turns[$ti].prompt")
        exp_mode=$(printf '%s'  "$line" | jq -r ".turns[$ti].mode // empty")
        cmd_re=$(printf '%s'    "$line" | jq -r ".turns[$ti].cmd_re // empty")
        forbid_re=$(printf '%s' "$line" | jq -r ".turns[$ti].forbid_re // empty")
        answer_max=$(printf '%s' "$line" | jq -r ".turns[$ti].answer_max // empty")
        last_cmd=; piped=
        if [ "$ti" = 0 ]; then sidmode=new; else sidmode=resume; fi
        score_turn
        [ "$ok" = 1 ] || run_ok=0
        seqdetail="${seqdetail}${seqdetail:+ | }t$((ti+1)):$tdetail"
        ti=$((ti + 1))
      done
      [ "$run_ok" = 1 ] && { cpass=$((cpass + 1)); passed=$((passed + 1)); }
      [ -z "$detail" ] && detail=$seqdetail
      total=$((total + 1))
    done

    if   [ "$cpass" = "$runs" ]; then mark="${G}✓${RST}"
    elif [ "$cpass" = 0 ];       then mark="${RED}✗${RST}"
    else                              mark="${Y}~${RST}"; fi
    printf '%s %s/%s  [multiturn] %s\n' "$mark" "$cpass" "$runs" "$label"
    printf '      %s%s%s\n' "$DIM" "$detail" "$RST"
    continue
  fi

  # -------- single-turn case --------
  prompt=$(printf '%s' "$line"     | jq -r '.prompt')
  exp_mode=$(printf '%s' "$line"   | jq -r '.mode // empty')
  cmd_re=$(printf '%s' "$line"     | jq -r '.cmd_re // empty')
  forbid_re=$(printf '%s' "$line"  | jq -r '.forbid_re // empty')
  answer_max=$(printf '%s' "$line" | jq -r '.answer_max // empty')
  last_cmd=$(printf '%s' "$line"   | jq -r '.last_cmd // empty')
  piped=$(printf '%s' "$line"      | jq -r '.piped // empty')
  sid=; sidmode=

  cpass=0; detail=; i=0
  while [ "$i" -lt "$runs" ]; do
    i=$((i + 1))
    score_turn
    [ "$ok" = 1 ] && { cpass=$((cpass + 1)); passed=$((passed + 1)); }
    [ -z "$detail" ] && detail=$tdetail
    total=$((total + 1))
  done

  if   [ "$cpass" = "$runs" ]; then mark="${G}✓${RST}"
  elif [ "$cpass" = 0 ];       then mark="${RED}✗${RST}"
  else                              mark="${Y}~${RST}"; fi
  printf '%s %s/%s  %s\n' "$mark" "$cpass" "$runs" "$prompt"
  printf '      %sexpect mode=%s%s%s  got %s%s\n' \
    "$DIM" "$exp_mode" "${cmd_re:+ cmd~/$cmd_re/}" "${answer_max:+ ans<=$answer_max w}" "$detail" "$RST"
done < "$cases"

printf '\n'
awk -v p="$passed" -v t="$total" -v m="$min" -v g="$G" -v r="$RED" -v x="$RST" 'BEGIN{
  s = (t ? p/t : 0);
  c = (s + 1e-9 < m) ? r : g;
  printf "%saggregate %.3f (%d/%d), min %.2f%s\n", c, s, p, t, m, x;
  exit (s + 1e-9 < m) ? 1 : 0
}'
