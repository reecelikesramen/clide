# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

clide turns a plain-English request into a shell command by wrapping `claude -p` (Claude Code's
headless mode) — using the user's existing Claude Code login, no API key. See README.md for the
user-facing pitch, flags, and privacy model.

## Architecture

There is **no build step and no test framework** — these are shell/PowerShell scripts run directly.

**POSIX core + thin shims.** The brain is `clide-core.sh` (POSIX `sh`), shared by the zsh and bash
shims. The shims own only the shell-specific bits; everything else lives in core.

- `clide-core.sh` — does redaction, builds the `<context>` block, calls `claude -p` (with the spinner
  + Esc/Ctrl-C cancel), parses the model's JSON via `jq`, runs destructive-command detection, and
  emits **one decision line on stdout** for the shim:
  The `claude` call is hermetic and shape-checked: `--safe-mode` (no user CLAUDE.md / hooks / skills /
  MCP can leak into or skew the translation), `--json-schema` (the reply shape is enforced at the
  claude level via a StructuredOutput tool — not just asked for in the prompt), and `--max-budget-usd`
  (`CLIDE_MAX_USD`, default 0.50). `clide.ps1` mirrors all three and must stay in sync by hand.
  `{"mode":"run|suggest|info|error|cancelled","cmd","note","explain","danger":0|1}`. It is **not run
  directly** — shims invoke it as `command sh "$core"` and pass everything via `CLIDE_*` env vars
  (`CLIDE_PROMPT`, `CLIDE_MODEL`, `CLIDE_EFFORT`, `CLIDE_FORCE_MODE`, `CLIDE_INSPECT`, `CLIDE_EXPLAIN`,
  `CLIDE_LAST_CMD`, `CLIDE_LAST_RC`, `CLIDE_SID`, `CLIDE_SID_MODE`, `CLIDE_INTERRUPTED`,
  `CLIDE_QUIET_ERR`, `CLIDE_SHELL`, `CLIDE_VERBOSE`). Piped stdin flows through to core as
  terminal-output context.
- `clide.zsh` / `clide.bash` — shims. Capture context (`$?` + previous command), manage per-tab
  session state, call core, then render: **suggest** → inject the command into the input buffer;
  **run** → print + confirm + `eval`. They locate core next to themselves (`${(%):-%x}` /
  `${BASH_SOURCE[0]}`), overridable via `$CLIDE_CORE`.
- `clide.ps1` — **standalone** reimplementation for PowerShell (Windows has no `sh`/`jq`): native
  `ConvertFrom-Json`, `Get-History`/`$LASTEXITCODE`, `$input`, `PSConsoleReadLine::Insert`. Keep it in
  sync with core's behavior by hand when changing the core contract.
- `install.sh` / `install.ps1` — installers. Default `BASE_URL` points at
  `raw.githubusercontent.com/reecelikesramen/clide/main`, so they fetch core + the matching shim from
  GitHub at install time. The repo is the single source of truth.

The two suggest-mode renderers differ by necessity: zsh uses `print -z` (true editable input buffer);
**bash cannot** push into the buffer from a function, so it does `history -s` + "press ↑". PowerShell
uses `PSConsoleReadLine::Insert`.

## Non-obvious invariants — preserve these when editing

- **Capture `$?` as the very first line** of the shim function (`_last_rc=$?`) before anything else
  clobbers it.
- **`claude` is always called with `</dev/null`** so it doesn't drain stdin and steal the `read -q`
  keypress; when stdin was a pipe, the run-mode confirm reads from `/dev/tty`.
- **Redaction uses `perl`, not `sed`** — `sed -E s///I` (case-insensitive) is GNU-only and breaks on
  macOS/BSD. `mktemp` has a `mktemp || mktemp -t clide` fallback for the same reason.
- **`--json-schema` enforces the reply shape**, so the prompt no longer needs to spell out the JSON
  format — but it is **not** bulletproof: on a non-actionable prompt the model can emit prose instead
  of a StructuredOutput call. So the prose→info fallback stays: if the reply isn't valid JSON (or has
  no `cmd`), core treats it as `mode:info` and prints it as an answer (exit 0) — not an error. Don't
  delete the `sed`-extract / `$out`-fallback parse.
- **`--safe-mode` keeps the translation hermetic.** Verified compatible with `--append-system-prompt`,
  `--effort`, `--session-id`/`--resume`, and the `-i` inspect path (`--allowedTools` +
  `--permission-mode`). It is not a latency win (API jitter dominates) — it's about isolation and
  reproducibility.
- **Per-tab memory** uses native `claude --session-id`/`--resume`, keyed by shell PID, state in
  `${XDG_RUNTIME_DIR:-/tmp}/clide-sessions/sess-<pid>` (`uuid turns ts`). Auto-rotates at 30 min idle
  or 10 turns; cleared on shell exit. A lost resume rotates + retries once, silenced via
  `CLIDE_QUIET_ERR=1` on the first attempt (don't let that re-fire non-quiet — use `if/else`, not
  `A && B || C`).
- **Esc/Ctrl-C cancel** → core exits 130 + `{"mode":"cancelled"}`; the shim writes the cancelled prompt
  to `sess-<pid>.int` and the next call feeds it back as `CLIDE_INTERRUPTED`. rc 130 must be excluded
  from the resume-retry.
- **Destructive guard** (in core) sets `danger:1` for `rm -rf`, `git push --force`, `git reset --hard`,
  `dd`, `mkfs`, etc. Run mode then requires typing the full word `yes`; `-y` does **not** bypass it.
- **Spinner/cancel need a real tty** (`stty`/`dd`/`read`); the non-tty branch is the synchronous
  fallback. Color is ANSI 256 #174 (Claude orange); frames are `· ✻ ✽ ✶ ✳ ✢`.
- **Fast defaults**: `haiku` + `--effort low`. There is no `/fast` in headless `claude -p` (Opus-only,
  interactive-only) — don't add it.
- **claude's stderr is captured, not discarded.** Core redirects `claude 2>"$tmperr"` (not
  `/dev/null`); the rc≠0 path prints it, and `-v`/`-vv` surface it. `clide.ps1` does the same via
  `2>&1` + filtering `ErrorRecord`s out of the pipeline. This is what makes "no response from claude"
  diagnosable (usually an unsupported flag on an older `claude`).
- **Verbose (`-v`/`-vv`, `CLIDE_VERBOSE=0|1|2`) must go to stderr only** — stdout carries the decision
  JSON the shim parses. `-v` = plan + exit code + claude stderr; `-vv` adds exact args, prompt, system
  prompt, raw output.
- **`clide.ps1` sets `[Console]::OutputEncoding` to UTF-8 (no BOM) at load** so Windows PowerShell 5.1
  renders the spinner frames/glyphs instead of `?` (its console defaults to the OEM codepage).
- **`clide.ps1` escapes `"`→`\"` in every claude arg before the native call** (`_qesc`/`$callArgs`).
  PowerShell's *legacy* native-arg passing (5.1, and 7.x in Legacy mode) strips embedded double quotes,
  which turned `--json-schema {"...":...}` into invalid JSON (`claude exited 1`). Exactly one PS→native
  boundary consumes the escaping in every shim shape (claude.exe, or claude.ps1/.cmd → node), so one
  `\"` level is correct. Skipped when `PSNativeCommandArgumentPassing` is `Standard`/`Windows` (7.3+),
  which already quotes correctly. Don't pass complex JSON to a native command unescaped on Windows.

## Working on this

Validate before committing (there are no automated tests):

```sh
sh -n clide-core.sh && zsh -n clide.zsh && bash -n clide.bash && sh -n install.sh   # syntax

# exercise core directly (stdout = decision JSON, stderr = spinner/info):
CLIDE_PROMPT="list git branches by date" CLIDE_MODEL=haiku sh ./clide-core.sh 2>/dev/null | jq .

# exercise a shim against the repo copy of core, in an isolated runtime dir:
CLIDE_CORE=$PWD/clide-core.sh XDG_RUNTIME_DIR=/tmp/clide-t zsh -ic \
  'source ./clide.zsh; clide -s "show current branch"'

# installer end-to-end in a throwaway HOME (fetches shims from GitHub raw):
HOME=/tmp/fakehome sh ./install.sh --shell zsh   # then: ... --uninstall
```

Note: the sandbox/CI has **no interactive tty**, so the spinner, Esc-cancel, and the actual `read -q`
keypress can't be exercised here — they take the sync path. `clide.ps1`/`install.ps1` need a real
`pwsh` to test (none in the Linux dev env).

## Publishing

The repo is the source of truth. Installers are served from `holmdahl.io/clide/install.{sh,ps1}`
(thin-proxy: only those 2 files live on the site; shims come from GitHub raw, so shim changes need **no
site update**). When the installer logic itself changes, re-copy the 2 files into the holmdahl.io repo
and push. After pushing a core/shim change, GitHub raw serves it within ~5 min (Fastly cache).
