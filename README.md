# clide

**Ask your terminal in plain English, get the command.**

> Do you forget git commands?
> A) Yes
> B) Yes, but I'm too embarrassed to say
> C) No\*
>
> \**(lying)*

Same. I've typed `git push --set-upstream origin` wrong enough times to feel something. So I built
**clide** — a thin wrapper around Claude Code's headless mode that turns a plain-English request into a
shell command, without opening the full interactive session.

```
$ clide list branches by last commit date
  # → command drops into your prompt, editable — you hit Enter
$ clide undo my last commit but keep my changes
  $ git reset --soft HEAD~1
  run this? [y/N]
$ git rebase main 2>&1 | clide fix this
  # → pipe an error in for context
```

**Best part:** if you've got Claude Code installed and you're signed in, it just works — no API key, no
separate subscription, no per-token billing. It rides your existing login. Works in zsh, bash, and
PowerShell.

## How it works

clide figures out what you actually want and returns one line of JSON behind the scenes:

- **a question** ("what's the command to…", "how do I…") → answers it;
- **a command** → **suggest** mode: drops the command into your shell's input buffer (zsh/pwsh) or
  history (bash), editable — you press Enter to run it;
- **do it for me** ("fix…", "delete…", "rebase…") → **run** mode: prints the command and asks `[y/N]`
  before executing.

It's not flying blind:

- **Shell context, automatically** — your previous command + its exit code, plus anything you
  **pipe in** (`cmd 2>&1 | clide fix this`).
- **Tab memory** — it remembers earlier clide runs in the *same terminal tab*, so follow-ups like
  *"that failed, try the other way"* actually work (details below).
- **Secret filtering** — a best-effort pass strips tokens / passwords / keys / JWTs before anything
  leaves your machine. (Best-effort, not airtight — don't pipe in your whole secrets file.)
- **Works with `sudo`** — for admin tasks it prefixes `sudo` (or `gsudo` on Windows) instead of
  claiming it can't elevate.
- **Esc cancels** mid-thought, and `clide code` kicks the whole conversation into an interactive
  Claude Code session when a one-liner won't cut it.

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

## License

MIT — see [LICENSE](LICENSE).
