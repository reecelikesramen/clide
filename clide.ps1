# clide.ps1 — PowerShell version of clide (self-contained; no jq / no sh needed)
# Install: dot-source from your $PROFILE:  . /path/to/clide.ps1
#
# Usage mirrors the shell versions:
#   clide <prompt...>        auto-classify: passive→suggest (inject), active→run (confirm)
#   clide -mh|-ms|-mo ...    model haiku|sonnet|opus  (default haiku, fast)
#   clide -E <level> ...     effort low|medium|high|xhigh|max (default low)
#   clide -r | -s ...        force run | suggest mode
#   clide -i | -e | -y ...   inspect | explain | auto-yes
#   clide -h                 help
#   <something> | clide …    pipe output/errors in as context

# Render the spinner frames + glyphs as UTF-8. Windows PowerShell 5.1 defaults the console to the OEM
# codepage, which turns ✻ ✽ ✶ ✳ ✢ into "?" (Claude Code's own UI works because it sets this too).
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

# ---- per-tab session memory (keyed by this pwsh process id) ----
$script:ClideSdir = Join-Path ([System.IO.Path]::GetTempPath()) 'clide-sessions'
Register-EngineEvent PowerShell.Exiting -SupportEvent -Action {
    Remove-Item (Join-Path ([System.IO.Path]::GetTempPath()) "clide-sessions/sess-$PID") -ErrorAction SilentlyContinue
} | Out-Null

function clide {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest)

    $lastRc = $LASTEXITCODE                       # exit code of previous command (capture FIRST)
    $tty = -not [Console]::IsOutputRedirected
    $sfile = Join-Path $script:ClideSdir "sess-$PID"

    # ---- colors set after; escalation handled below once colors exist ----

    # ---- colors (PSStyle on pwsh 7.2+, else ANSI literals) ----
    $e = [char]27
    $A = "$e[38;5;174m"; $D = "$e[38;5;244m"; $ER = "$e[38;5;203m"
    $OK = "$e[38;5;78m"; $CMD = "$e[38;5;81m"; $R = "$e[0m"
    if (-not $tty) { $A = $D = $ER = $OK = $CMD = $R = "" }

    # ---- escalation: exactly `clide code` ----
    if ($Rest.Count -eq 1 -and $Rest[0] -eq 'code') {
        if (Test-Path $sfile) {
            $euuid = (Get-Content $sfile -ErrorAction SilentlyContinue).Split(' ')[0]
            if ($euuid) {
                Write-Host "${A}↗ elevating this tab into an interactive claude session…${R}"
                & claude --resume $euuid
                return
            }
        }
        Write-Host "${ER}✗${R} ${D}clide:${R} no context in this tab to elevate (run a clide command first)"
        return
    }

    # ---- capture piped input (terminal output/errors) ----
    $piped = ""
    if ($MyInvocation.ExpectingInput) { $piped = (@($input) -join "`n") }

    # ---- redaction: strip obvious secrets before sending ----
    function _redact([string] $t) {
        if (-not $t) { return $t }
        $t = $t -replace '(?i)((?:token|secret|passwd|password|api[_-]?key|access[_-]?key|bearer|authorization)\s*[=:]\s*)\S+', '${1}***'
        $t = $t -replace '(\w+://[^:/\s]+:)[^@\s]+(@)', '${1}***${2}'
        $t = $t -replace 'AKIA[0-9A-Z]{16}', 'AKIA****************'
        $t = $t -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '***JWT***'
        return $t
    }

    # ---- parse flags ----
    $model = ""; $effort = "low"; $forceMode = ""; $inspect = $false
    $explain = $false; $autoyes = $false; $once = $false; $newsess = $false; $verbose = 0
    $promptParts = @()
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        switch ($Rest[$i]) {
            '-mh' { $model = 'haiku' }
            '-ms' { $model = 'sonnet' }
            '-mo' { $model = 'opus' }
            '-E'  { $i++; $effort = $Rest[$i] }
            '-r'  { $forceMode = 'run' }
            '-s'  { $forceMode = 'suggest' }
            '-i'  { $inspect = $true }
            '-e'  { $explain = $true }
            '-y'  { $autoyes = $true }
            { $_ -in '-1', '--once' } { $once = $true }
            { $_ -in '-n', '--new' }  { $newsess = $true }
            '-v'  { if ($verbose -lt 1) { $verbose = 1 } }
            '-vv' { $verbose = 2 }
            { $_ -in '-h', '--help' } {
                Write-Host "${A}clide${R} — turn a prompt into a shell command"
                Write-Host "  ${D}clide <prompt>${R}        auto: passive→suggest (inject), active→run (confirm)"
                Write-Host "  ${D}-mh|-ms|-mo${R}           model haiku|sonnet|opus (default haiku, fast)"
                Write-Host "  ${D}-E <level>${R}            effort low|medium|high|xhigh|max (default low)"
                Write-Host "  ${D}-r | -s${R}               force run | suggest mode"
                Write-Host "  ${D}-i${R}                    read-only git inspection (→ sonnet/medium)"
                Write-Host "  ${D}-e | -y${R}               explain | auto-yes (destructive still gated)"
                Write-Host "  ${D}-1 | --once${R}           stateless one-off (ignore tab memory)"
                Write-Host "  ${D}-n | --new${R}            fresh tab session, then run (bare -n resets)"
                Write-Host "  ${D}-v | -vv${R}              verbose | very verbose (diagnose failures)"
                Write-Host "  ${D}clide code${R}            elevate tab context into interactive claude"
                Write-Host "  ${D}… | clide …${R}           pipe output/errors in as context"
                return
            }
            default { $promptParts += $Rest[$i] }
        }
    }
    $prompt = ($promptParts -join ' ')

    # bare `clide -n` → reset the tab session
    if ($newsess -and -not $prompt) {
        Remove-Item $sfile -ErrorAction SilentlyContinue
        Write-Host "${OK}↻${R} ${D}clide: tab session reset${R}"
        return
    }
    if (-not $prompt) { Write-Host "${ER}✗${R} ${D}clide:${R} no prompt (try clide -h)"; return }

    # ---- resolve tab session (uuid + mode) ----
    $sid = ""; $sidMode = "off"; $turns = 0
    if (-not $once) {
        $fUuid = ""; $fTurns = 0; $stale = $false
        if (Test-Path $sfile) {
            $parts = (Get-Content $sfile -ErrorAction SilentlyContinue).Split(' ')
            $fUuid = $parts[0]; if ($parts.Count -gt 1) { $fTurns = [int]$parts[1] }
            $ageMin = ((Get-Date) - (Get-Item $sfile).LastWriteTime).TotalMinutes
            if ($ageMin -gt 30) { $stale = $true }
        } else { $stale = $true }
        if (-not $fUuid) { $stale = $true }
        if ($fTurns -ge 10) { $stale = $true }
        if ($newsess -or $stale) {
            $sid = [guid]::NewGuid().ToString(); $sidMode = "new"; $turns = 0
        } else {
            $sid = $fUuid; $sidMode = "resume"; $turns = $fTurns
        }
    }

    if ($inspect) {
        if (-not $model)  { $model = 'sonnet' }
        if (-not $effort) { $effort = 'medium' }
    }
    if (-not $model) { $model = 'haiku' }

    # ---- previous command (Get-History; the clide call isn't in history yet) ----
    $lastCmd = _redact ((Get-History -Count 1 -ErrorAction SilentlyContinue).CommandLine)
    $piped = _redact $piped

    # ---- carry forward a previously interrupted request (then clear it) ----
    $interrupted = ""
    if (Test-Path "$sfile.int") {
        $interrupted = _redact (Get-Content "$sfile.int" -Raw -ErrorAction SilentlyContinue)
        Remove-Item "$sfile.int" -ErrorAction SilentlyContinue
    }

    # ---- build context + full prompt ----
    $ctx = ""
    if ($lastCmd)     { $ctx += "Previous command (exit $lastRc): $lastCmd`n" }
    if ($piped)       { $ctx += "Piped terminal output:`n$piped`n" }
    if ($interrupted) { $ctx += "Note: the user interrupted (cancelled) this earlier request before you answered: $interrupted`n" }
    $fullPrompt = $prompt
    if ($ctx) { $fullPrompt = "<context>`n$ctx</context>`n`nRequest: $prompt" }

    $explainClause = if ($explain) { 'Also include an "explain" field: one short sentence on what the command does.' } else { '' }

    # detect an elevation helper so the model elevates instead of refusing
    $elev = if (Get-Command sudo -ErrorAction SilentlyContinue) { 'sudo' }
            elseif (Get-Command gsudo -ErrorAction SilentlyContinue) { 'gsudo' } else { '' }
    $osName = if ($IsWindows) { 'Windows PowerShell' } else { 'PowerShell' }
    $elevClause = if ($elev) {
        "This is $osName. ``$elev`` is installed for elevation. For any command needing administrator/root rights, prefix it with ``$elev `` (e.g. ``$elev Stop-Service Spooler``, ``$elev netsh ...``). NEVER claim you cannot elevate or run privileged commands — emit the ``$elev``-prefixed command."
    } else { "This is $osName. Prefer native PowerShell cmdlets." }
    $sys = @"
You translate the user request into ONE shell command for their terminal. Producing a command is
your default and your job: treat almost every request as actionable, including playful ones
("tell a joke with echo" -> an echo/Write-Output command) and edits ("fix that line" -> a one-liner).
$elevClause
You may receive a <context> block with the previous command, its exit code, and piped output/errors;
use it to resolve "that"/"this"/"the error" and to fix failures. Never echo secrets from context.
Your reply is validated against a JSON schema with fields: mode (run|suggest|info), cmd, answer, note.
Put the command in "cmd" (omit only when mode=info); put info-mode prose in "answer"; "note" is an
optional <=8 word why.
$explainClause
Choose mode:
- "run" — you can produce a COMPLETE, unambiguous command AND the request is a directive to act
  (fix, delete, create, clean, restart, "do X for me"). clide runs it after a y/N confirm.
- "suggest" — you have a command but the user should review or edit it first: placeholders / paths /
  names to fill in, exploratory, or ambiguous args. It lands in their editable buffer; they press
  Enter. When torn between run and suggest, choose suggest.
- "info" — ONLY for a genuine knowledge / why / explanation question with no command form (e.g.
  "why did the last 3 attempts fail?"). Put the prose in "answer" and omit "cmd". Do NOT fall back to
  info just because a request is casual, playful, or underspecified — emit your best command instead.
cmd must be a runnable command line for this shell, no fences, no leading $.
Keep it to a single line. Prefer safe, idempotent forms when reasonable.
If underspecified, still emit your single best-guess command (run or suggest) with the caveat in
"note" — never refuse, never ask questions, never apologize. Output nothing but the one JSON line.
"@

    # ---- build claude args ----
    # JSON Schema enforces the reply shape at the claude level (StructuredOutput tool).
    $schema = '{"type":"object","properties":{"mode":{"type":"string","enum":["run","suggest","info"]},"cmd":{"type":"string"},"answer":{"type":"string"},"note":{"type":"string"},"explain":{"type":"string"}},"required":["mode"]}'
    $maxUsd = if ($env:CLIDE_MAX_USD) { $env:CLIDE_MAX_USD } else { '0.50' }
    # --safe-mode: hermetic translation (no user CLAUDE.md / hooks / skills / MCP leaking in).
    $cargs = @('-p', $fullPrompt, '--model', $model, '--output-format', 'text',
               '--append-system-prompt', $sys, '--exclude-dynamic-system-prompt-sections',
               '--safe-mode', '--json-schema', $schema, '--max-budget-usd', $maxUsd)
    if ($effort) { $cargs += @('--effort', $effort) }
    if ($inspect) {
        $cargs += @('--allowedTools', 'Bash(git status:*) Bash(git log:*) Bash(git branch:*) Bash(git remote:*)',
                    '--permission-mode', 'acceptEdits')
    } else {
        $cargs += @('--disallowedTools', 'Bash Edit Write')
    }

    # ---- verbose diagnostics ----
    if ($verbose -ge 1) {
        $fm = if ($forceMode) { $forceMode } else { 'auto' }
        [Console]::Error.WriteLine("${D}clide -v: model=$model effort=$effort mode=$fm session=$sidMode inspect=$inspect${R}")
    }

    # run claude capturing stdout + stderr + exit code (stderr is what diagnoses failures)
    $invoke = {
        param($a)
        $raw  = & claude @a 2>&1
        $errs = ($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
        $outs = ($raw | Where-Object { -not ($_ -is [System.Management.Automation.ErrorRecord]) } | ForEach-Object { [string]$_ }) -join "`n"
        [pscustomobject]@{ Out = $outs; Err = $errs; Code = $LASTEXITCODE }
    }

    # PowerShell's legacy native-arg passing (5.1, and 7.x in Legacy mode) strips embedded double
    # quotes when calling native programs, so --json-schema '{"type":...}' reaches claude as invalid
    # JSON. Escape " as \" ourselves so the program's argv parser gets literal quotes — unless this
    # PowerShell already quotes correctly (PSNativeCommandArgumentPassing = Standard/Windows on 7.3+).
    $napMode = (Get-Variable PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue)
    $nativeQuotesOk = ($PSVersionTable.PSVersion.Major -ge 7) -and ($napMode -in 'Standard', 'Windows')
    function _qesc([string] $s) { if ($nativeQuotesOk) { $s } else { $s -replace '"', '\"' } }

    # ---- call claude (spinner via job; sync fallback), retrying once if a resume is lost ----
    $out = $null; $stderrText = ''; $code = 0; $cancelled = $false
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $sargs = $cargs
        if ($sidMode -eq 'new')        { $sargs = $cargs + @('--session-id', $sid) }
        elseif ($sidMode -eq 'resume') { $sargs = $cargs + @('--resume', $sid) }
        $callArgs = @($sargs | ForEach-Object { _qesc $_ })   # quote-safe copy for the native call
        if ($verbose -ge 2 -and $attempt -eq 0) {
            [Console]::Error.WriteLine("${D}clide -vv: claude $($sargs -join ' ')${R}")
            [Console]::Error.WriteLine("${D}clide -vv: --- prompt ---`n$fullPrompt${R}")
            [Console]::Error.WriteLine("${D}clide -vv: --- system ---`n$sys${R}")
        }
        try {
            $job = Start-Job -ScriptBlock $invoke -ArgumentList (, $callArgs)
            if ($tty) {
                $frames = '·','✻','✽','✶','✳','✢'; $k = 0
                [Console]::Write("$e[?25l")
                while ($job.State -eq 'Running') {
                    [Console]::Error.Write("`r$A$($frames[$k])$R ${D}thinking · $model  (esc cancels)$R")
                    if ([Console]::KeyAvailable) {
                        if ([Console]::ReadKey($true).Key -eq 'Escape') { $cancelled = $true; Stop-Job $job; break }
                    }
                    Start-Sleep -Milliseconds 80; $k = ($k + 1) % $frames.Count
                }
                [Console]::Error.Write("`r$e[K"); [Console]::Write("$e[?25h")
            } else {
                Wait-Job $job | Out-Null
            }
            if (-not $cancelled) { $res = Receive-Job $job; if ($res) { $out = $res.Out; $stderrText = $res.Err; $code = [int]$res.Code } }
            Remove-Job $job -Force
        } catch {
            if (-not $cancelled) { $res = & $invoke $callArgs; $out = $res.Out; $stderrText = $res.Err; $code = [int]$res.Code }
        }
        if ($verbose -ge 1) { [Console]::Error.WriteLine("${D}clide -v: claude exit=$code, out=$(($out + '').Length)ch, err=$(($stderrText + '').Length)ch${R}") }
        if ($verbose -ge 1 -and $stderrText) { [Console]::Error.WriteLine("${D}clide -v: --- claude stderr ---`n$stderrText${R}") }
        if ($verbose -ge 2 -and $out)        { [Console]::Error.WriteLine("${D}clide -vv: --- raw output ---`n$out${R}") }
        if ($cancelled -or $out) { break }
        if ($sidMode -eq 'resume') {                 # lost session → rotate + retry
            $sid = [guid]::NewGuid().ToString(); $sidMode = 'new'; $turns = 0
        } else { break }
    }

    if ($cancelled) {
        New-Item -ItemType Directory -Path $script:ClideSdir -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path "$sfile.int" -Value $prompt
        Write-Host "${D}✗ interrupted${R}"
        return
    }
    if (-not $out) {
        $why = if ($code) { " (claude exited $code)" } else { "" }
        Write-Host "${ER}✗${R} ${D}clide:${R} no response from claude$why"
        if ($stderrText)        { Write-Host "${D}$stderrText${R}" }
        elseif ($verbose -lt 1) { Write-Host "${D}(re-run with -v or -vv to see why)${R}" }
        return
    }

    # ---- persist tab session (unless stateless) ----
    if (-not $once -and $sid) {
        New-Item -ItemType Directory -Path $script:ClideSdir -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path $sfile -Value ("{0} {1} {2}" -f $sid, ($turns + 1), [int][double]::Parse((Get-Date -UFormat %s)))
    }

    # ---- parse JSON (grab first {...}) ----
    $m = [regex]::Match($out, '\{.*\}')
    $obj = $null
    if ($m.Success) { try { $obj = $m.Value | ConvertFrom-Json } catch { $obj = $null } }

    if (-not $obj -or $obj.mode -eq 'info' -or -not $obj.cmd) {
        $answer = if ($obj -and $obj.answer) { [string]$obj.answer } else { $out }
        Write-Host "${A}ℹ${R} ${D}answer:${R}"
        Write-Host $answer
        return
    }

    $cmd = [string]$obj.cmd
    $mode = if ($forceMode) { $forceMode } elseif ($obj.mode -eq 'run') { 'run' } else { 'suggest' }
    $note = [string]$obj.note
    $explainTxt = [string]$obj.explain

    # ---- destructive detection ----
    $danger = $false
    $danglers = @(
        'rm\s+-[rf]+', 'Remove-Item.*-Recurse.*-Force', '\bdd\s', 'mkfs', ':\(\)\{',
        '>\s*/dev/sd', 'of=/dev/', 'chmod\s+-R\s+777', '\bshred\b', '\btruncate\b',
        'git\s+push.*(--force|\s-f\b)', 'git\s+clean\s+-[a-z]*f', 'git\s+reset\s+--hard',
        'Format-Volume', 'rmdir\s+/s'
    )
    foreach ($p in $danglers) { if ($cmd -match $p) { $danger = $true; break } }

    if ($explainTxt) { Write-Host "${D}» $explainTxt${R}" }
    if ($note)       { Write-Host "${D}› $note${R}" }
    if ($danger)     { Write-Host "${ER}⚠ DESTRUCTIVE${R} ${D}— review carefully${R}" }

    if ($mode -eq 'suggest') {
        try {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($cmd)   # editable in the prompt buffer
        } catch {
            Write-Host "${CMD}> $cmd${R}"
            Write-Host "${D}(copy above — PSReadLine buffer insert unavailable)${R}"
        }
    } else {
        Write-Host "${CMD}> $cmd${R}"
        if ($danger) {
            $ans = Read-Host "${ER}type 'yes' to run${R}"
            if ($ans -eq 'yes') { Invoke-Expression $cmd } else { Write-Host "${D}✗ skipped${R}" }
        } elseif ($autoyes) {
            Invoke-Expression $cmd
        } else {
            $ans = Read-Host "${D}run this? [y/N]${R}"
            if ($ans -match '^[yY]') { Invoke-Expression $cmd } else { Write-Host "${D}✗ skipped${R}" }
        }
    }
}
