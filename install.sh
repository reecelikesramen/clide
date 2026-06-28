#!/bin/sh
# clide installer (zsh + bash).  Usage:
#   curl -fsSL https://holmdahl.io/clide/install.sh | sh
#   ...| sh -s -- --shell zsh        # force a shell
#   ...| sh -s -- --uninstall
#
# Honors:  CLIDE_BASE_URL (where to fetch files), CLIDE_DIR (install location).
set -eu

BASE_URL="${CLIDE_BASE_URL:-https://raw.githubusercontent.com/reecelikesramen/clide/main}"   # source of truth
DIR="${CLIDE_DIR:-$HOME/.config/clide}"
SHELL_OVERRIDE=""
UNINSTALL=0
MARK_BEGIN="# >>> clide >>>"
MARK_END="# <<< clide <<<"

while [ $# -gt 0 ]; do
  case "$1" in
    --shell) SHELL_OVERRIDE="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    -h|--help) echo "clide installer: [--shell zsh|bash] [--uninstall] [--base-url URL]"; exit 0 ;;
    *) echo "clide: unknown arg $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[38;5;39m%s\033[0m\n' "$*"; }
warn() { printf '\033[38;5;203m%s\033[0m\n' "$*" >&2; }

# ---- detect shell ----
detect_shell() {
  if [ -n "$SHELL_OVERRIDE" ]; then echo "$SHELL_OVERRIDE"; return; fi
  case "${SHELL:-}" in
    *zsh)  echo zsh; return ;;
    *bash) echo bash; return ;;
  esac
  # fallback: inspect parent process
  parent=$(ps -p "${PPID:-$$}" -o comm= 2>/dev/null | sed 's/^-//')
  case "$parent" in
    *zsh)  echo zsh ;;
    *bash) echo bash ;;
    *)     echo zsh ;;   # sensible default
  esac
}

rc_file() {
  case "$1" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" || echo "$HOME/.bash_profile" ;;
  esac
}

# ---- fetch helper (http or file://) ----
fetch() {
  url="$1"; dest="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$dest" "$url"
  else warn "need curl or wget"; exit 1
  fi
}

SH=$(detect_shell)
RC=$(rc_file "$SH")
SHIM="clide.$SH"

# ---- uninstall ----
if [ "$UNINSTALL" = 1 ]; then
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -f "$f" ] || continue
    if grep -qF "$MARK_BEGIN" "$f"; then
      tmp=$(mktemp 2>/dev/null) || tmp=$(mktemp -t clide)
      sed "/$MARK_BEGIN/,/$MARK_END/d" "$f" > "$tmp" && cat "$tmp" > "$f" && rm -f "$tmp"
      say "removed clide block from $f"
    fi
  done
  rm -rf "$DIR"
  say "clide uninstalled. Restart your shell."
  exit 0
fi

# ---- dependency check ----
missing=""
command -v claude >/dev/null 2>&1 || missing="$missing claude"
command -v jq     >/dev/null 2>&1 || missing="$missing jq"
command -v perl   >/dev/null 2>&1 || missing="$missing perl"
if [ -n "$missing" ]; then
  warn "missing dependencies:$missing"
  warn "  claude: https://claude.com/claude-code   jq/perl: your package manager"
  [ "${missing#* claude}" != "$missing" ] && { warn "claude is required — aborting."; exit 1; }
fi

# ---- install files ----
mkdir -p "$DIR"
say "downloading clide core + $SHIM from $BASE_URL"
fetch "$BASE_URL/clide-core.sh" "$DIR/clide-core.sh"
fetch "$BASE_URL/$SHIM"         "$DIR/$SHIM"
chmod +x "$DIR/clide-core.sh"

# ---- wire into rc file (idempotent) ----
if grep -qF "$MARK_BEGIN" "$RC" 2>/dev/null; then
  say "already wired into $RC (left as-is)"
else
  {
    echo ""
    echo "$MARK_BEGIN"
    echo "source \"$DIR/$SHIM\""
    echo "$MARK_END"
  } >> "$RC"
  say "added source line to $RC"
fi

say "done — clide installed for $SH."
say "to use it in THIS shell now, run:"
say "  source \"$DIR/$SHIM\""
say "(new shells pick it up automatically.)"
