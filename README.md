# clide

Type what you want in plain English, get the shell command.

I forget git flags constantly. `clide` is a small wrapper over Claude Code's headless mode that turns
a sentence into a command — no full interactive session, no leaving the terminal.

```
$ clide list branches by last commit date
  # command drops into your prompt, editable — hit Enter
$ clide undo my last commit but keep my changes
  $ git reset --soft HEAD~1
  run this? [y/N]
$ git rebase main 2>&1 | clide fix this
  # pipe an error in for context
```

If you have Claude Code installed and signed in, it just works: no API key, no extra subscription, no
per-token billing — it uses your existing login. zsh, bash, PowerShell.

## How it works

Almost every request becomes a command (even `clide tell me a joke with echo`). clide picks one of
three modes:

- **suggest** — needs your eyes first (a path to fill in, ambiguous args). Drops the command into your
  input buffer (zsh/pwsh) or history (bash) so you can edit and press Enter.
- **run** — a directive with a complete command ("fix…", "delete…", "rebase…"). clide prints it, asks
  `[y/N]`, then runs it.
- **info** — a real why-question with no command form. clide answers in prose, does nothing else.

It knows your OS and shell, so it reaches for the right tools (BSD vs GNU `sed -i`). And it has
context:

- **Shell context** — your last command + its exit code, plus anything you pipe in.
- **Tab memory** — remembers earlier clide runs in the same tab, so "that failed, try the other way"
  works (below).
- **Secret filtering** — best-effort strip of tokens/passwords/keys/JWTs before anything leaves your
  machine. Not airtight; don't pipe in your secrets file.
- **sudo** — prefixes `sudo` (or `gsudo` on Windows) for admin tasks instead of refusing to elevate.
- **Esc** cancels mid-thought. `clide code` kicks the conversation into an interactive Claude Code
  session when a one-liner won't cut it.

## Install

**zsh / bash (Linux, macOS):**
```sh
curl -fsSL https://holmdahl.io/clide/install.sh | sh   # detects your shell
# force a shell:  ...| sh -s -- --shell bash      uninstall:  ...| sh -s -- --uninstall
```

**PowerShell (Windows, or pwsh anywhere):**
```powershell
irm https://holmdahl.io/clide/install.ps1 | iex
```

**Or from a clone:**
```sh
git clone https://github.com/reecelikesramen/clide ~/clide
echo 'source ~/clide/clide.zsh' >> ~/.zshrc     # or clide.bash >> ~/.bashrc
exec $SHELL
```

The install scripts are served from holmdahl.io; they fetch the function files straight from this
GitHub repo (`main`). Requires `claude` (Claude Code) and that you're signed in. The shell version
also needs `jq` and `perl` (both ship on macOS and most Linux). The PowerShell version needs neither.

## Flags

| Flag | Meaning |
|------|---------|
| `-mh` / `-ms` / `-mo` | model haiku / sonnet / opus (default **haiku**, fast) |
| `-E <level>` | effort: low/medium/high/xhigh/max (default **low**) |
| `-r` / `-s` | force run / suggest mode |
| `-i` | allow read-only git inspection (bumps to sonnet/medium) |
| `-e` | add a one-line explanation |
| `-y` | auto-yes in run mode (destructive commands still gated) |
| `-1` / `--once` | stateless one-off — ignore this tab's memory |
| `-n` / `--new` | start a fresh tab session, then run (bare `clide -n` just resets) |
| `-v` / `-vv` | verbose / very verbose — print the resolved plan, claude's exit code & stderr (`-vv` adds the exact args, prompt, system prompt, and raw output) to diagnose failures |
| `clide code` | elevate this tab's context into an interactive Claude Code session |
| `cmd 2>&1 \| clide …` | pipe output/errors in as context |

## Memory (per terminal tab)

clide remembers the conversation **within a terminal tab**, so follow-ups have context:

```
$ clide help me rebase this branch onto main
$ clide that failed — the upstream moved, adjust
$ clide try again
```

This uses Claude's native session resume (`--session-id` / `--resume`) — each call continues the
same conversation. Sessions are:

- **keyed per tab** (the shell's PID) — separate tabs are independent;
- **auto-rotated** after 30 minutes idle or ~10 turns (resume cost grows with history, so this keeps
  it snappy);
- **cleared** when the tab closes (and the whole store clears on reboot).

Controls: `clide -1 <prompt>` for a stateless one-off, `clide -n` to reset the tab (or `-n <prompt>`
to reset then run).

**Cancel while it's thinking:** press **Esc** (or Ctrl-C) during the spinner to stop the request and
return to your prompt. A cancelled request is remembered — your next `clide` call gets told what you
were asking, so "actually, do X instead" still has context.

### `clide code` — escalate to interactive

When a task outgrows one-liners, run **`clide code`** (exactly, no other words). It opens the tab's
accumulated conversation in the interactive Claude Code TUI via `claude --resume`, so you continue
with full context. If the tab has no prior clide turns, it tells you there's nothing to elevate.

## Speed

Default is **haiku + `--effort low`** — fastest for one-liners. Escalate with `-ms`/`-mo` (and
`-E medium/high`) for harder, stateful tasks. Note: Claude Code's interactive `/fast` mode is **not
available in headless `claude -p`** and is Opus-only regardless, so it doesn't apply here — model and
effort are the real latency levers.

## Privacy / security

- Context (previous command + piped text) is sent to Anthropic via your Claude subscription.
- **Secrets are redacted before sending** — `token=`/`api_key=`/`password=`/`bearer …`, URL inline
  credentials (`user:pw@host`), AWS keys (`AKIA…`), and JWTs. Redaction is **best-effort, not a
  guarantee** — don't pipe in things you wouldn't want sent.
- No shell-history scraping, no scrollback capture — only the single previous command and what you
  explicitly pipe.
- **Hermetic translation** — the headless `claude` call runs in `--safe-mode`, so your personal Claude
  Code config (global `CLAUDE.md`, hooks, skills, MCP servers) can't leak into or skew the command it
  produces. Spend per call is capped (`--max-budget-usd`, default `$0.50`; override `CLIDE_MAX_USD`).
- **Tab memory** keeps a Claude session per tab; the conversation lives in Claude Code's local
  session store and is cleared on tab close / reboot. Use `clide -1` for a stateless call.
- **Destructive guard:** commands like `rm -rf`, `git push --force`, `dd`, `mkfs` are flagged; run mode
  requires typing the full word `yes`, and `-y` does **not** bypass that gate.
- Run mode uses `eval`/`Invoke-Expression` only after your confirmation.

## Shell notes

- **zsh** — full experience; suggest mode injects via `print -z` (editable input buffer).
- **bash** — bash can't push text into the input buffer from a function, so suggest mode prints the
  command and adds it to history: **press ↑ to edit and run**. (Power users can bind a `bind -x` widget
  using `READLINE_LINE`; see the function source.)
- **PowerShell** — suggest mode injects via `PSConsoleReadLine::Insert` (true editable buffer). The
  installer provisions a `sudo` helper (native `sudo` on Win11 24H2, else `gsudo` via
  winget/scoop/choco), and clide tells the model to prefix admin commands with it (e.g.
  `sudo Stop-Service …`) rather than claiming it can't elevate.

## Files

```
clide-core.sh   POSIX core (claude call, redaction, JSON parse, danger detection) — shared by zsh+bash
clide.zsh       zsh shim
clide.bash      bash shim
clide.ps1       standalone PowerShell version
install.sh      zsh/bash installer (shell-detecting)
install.ps1     PowerShell installer
```

## Developing — prompt eval

The classifier (command-first bias, run vs suggest vs info) lives entirely in the system prompt in
`clide-core.sh`. To keep it honest there's an offline scorer:

```sh
sh eval/run.sh                 # defaults to haiku + --effort low (what ships)
sh eval/run.sh --runs 5        # more samples per case to smooth model nondeterminism
sh eval/run.sh --model sonnet --effort medium   # is a miss a prompt problem or a model problem?
```

It runs each case in `eval/cases.jsonl` against the real core and checks the emitted mode (and a
regex on the command) against expectations, printing a per-case ✓/✗ and an aggregate score. It exits
non-zero when the score drops below `--min` (default 0.8), so the loop is: edit the prompt → run →
watch the number. Add a case whenever clide misclassifies something in the wild.

## License

MIT — see [LICENSE](LICENSE).
