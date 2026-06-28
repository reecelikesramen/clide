#!/bin/sh
# eval/run.sh — offline scorer for clide's classifier + system prompt.
#
# Runs each case in eval/cases.jsonl against the real clide-core.sh and checks the
# emitted decision (mode + cmd) against expectations. Defaults to the shipped
# haiku + --effort low, since that's what most clide calls use.
#
# Loop: edit the SYS prompt in clide-core.sh, run this, watch the aggregate score.
#
# Usage:
#   sh eval/run.sh [--model haiku] [--effort low] [--runs 3] [--cases file] [--min 0.8]
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

while [ $# -gt 0 ]; do
  case "$1" in
    --model)  model=$2;  shift 2 ;;
    --effort) effort=$2; shift 2 ;;
    --runs)   runs=$2;   shift 2 ;;
    --cases)  cases=$2;  shift 2 ;;
    --min)    min=$2;    shift 2 ;;
    -h|--help)
      printf 'usage: run.sh [--model m] [--effort e] [--runs n] [--cases f] [--min r]\n'; exit 0 ;;
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

total=0; passed=0
printf '%sclide eval — model=%s effort=%s runs=%s%s\n\n' "$DIM" "$model" "$effort" "$runs" "$RST"

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac

  prompt=$(printf '%s' "$line"    | jq -r '.prompt')
  exp_mode=$(printf '%s' "$line"  | jq -r '.mode // empty')
  cmd_re=$(printf '%s' "$line"    | jq -r '.cmd_re // empty')
  forbid_re=$(printf '%s' "$line" | jq -r '.forbid_re // empty')
  last_cmd=$(printf '%s' "$line"  | jq -r '.last_cmd // empty')
  piped=$(printf '%s' "$line"     | jq -r '.piped // empty')

  cpass=0; detail=; i=0
  while [ "$i" -lt "$runs" ]; do
    i=$((i + 1))
    if [ -n "$piped" ]; then
      decision=$(printf '%s' "$piped" | CLIDE_PROMPT="$prompt" CLIDE_MODEL="$model" \
        CLIDE_EFFORT="$effort" CLIDE_LAST_CMD="$last_cmd" CLIDE_QUIET_ERR=1 CLIDE_SHELL=sh \
        sh "$core" 2>/dev/null)
    else
      decision=$(CLIDE_PROMPT="$prompt" CLIDE_MODEL="$model" CLIDE_EFFORT="$effort" \
        CLIDE_LAST_CMD="$last_cmd" CLIDE_QUIET_ERR=1 CLIDE_SHELL=sh \
        sh "$core" </dev/null 2>/dev/null)
    fi
    act_mode=$(printf '%s' "$decision" | jq -r '.mode // "error"' 2>/dev/null)
    act_cmd=$(printf '%s' "$decision"  | jq -r '.cmd  // empty'   2>/dev/null)

    ok=1
    [ -n "$exp_mode" ]  && { printf '%s' "$act_mode" | grep -qE "^($exp_mode)\$" || ok=0; }
    [ -n "$cmd_re" ]    && { printf '%s' "$act_cmd"  | grep -qE "$cmd_re"        || ok=0; }
    [ -n "$forbid_re" ] && { printf '%s' "$act_cmd"  | grep -qE "$forbid_re"     && ok=0; }

    [ "$ok" = 1 ] && { cpass=$((cpass + 1)); passed=$((passed + 1)); }
    [ -z "$detail" ] && detail="$act_mode${act_cmd:+: $act_cmd}"
    total=$((total + 1))
  done

  if   [ "$cpass" = "$runs" ]; then mark="${G}✓${RST}"
  elif [ "$cpass" = 0 ];       then mark="${RED}✗${RST}"
  else                              mark="${Y}~${RST}"; fi
  printf '%s %s/%s  %s\n' "$mark" "$cpass" "$runs" "$prompt"
  printf '      %sexpect mode=%s%s  got %s%s\n' \
    "$DIM" "$exp_mode" "${cmd_re:+ cmd~/$cmd_re/}" "$detail" "$RST"
done < "$cases"

printf '\n'
awk -v p="$passed" -v t="$total" -v m="$min" -v g="$G" -v r="$RED" -v x="$RST" 'BEGIN{
  s = (t ? p/t : 0);
  c = (s + 1e-9 < m) ? r : g;
  printf "%saggregate %.3f (%d/%d), min %.2f%s\n", c, s, p, t, m, x;
  exit (s + 1e-9 < m) ? 1 : 0
}'
