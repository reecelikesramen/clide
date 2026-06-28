# clide installer (PowerShell).  Usage:
#   irm https://holmdahl.io/clide/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://holmdahl.io/clide/install.ps1))) -Uninstall
#
# Honors: $env:CLIDE_BASE_URL, $env:CLIDE_DIR
param([switch] $Uninstall)

$BaseUrl = if ($env:CLIDE_BASE_URL) { $env:CLIDE_BASE_URL } else { 'https://raw.githubusercontent.com/reecelikesramen/clide/main' }  # source of truth
$Dir     = if ($env:CLIDE_DIR)      { $env:CLIDE_DIR }      else { Join-Path $HOME '.config/clide' }
$Target  = Join-Path $Dir 'clide.ps1'
$MarkBeg = '# >>> clide >>>'
$MarkEnd = '# <<< clide <<<'

function Say([string]$m)  { Write-Host $m -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host $m -ForegroundColor Red }

# ---- ensure $PROFILE exists ----
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }

if ($Uninstall) {
    if (Test-Path $PROFILE) {
        $lines = Get-Content $PROFILE
        $out = @(); $skip = $false
        foreach ($l in $lines) {
            if ($l -eq $MarkBeg) { $skip = $true; continue }
            if ($l -eq $MarkEnd) { $skip = $false; continue }
            if (-not $skip) { $out += $l }
        }
        Set-Content -Path $PROFILE -Value $out
        Say "removed clide block from $PROFILE"
    }
    if (Test-Path $Target) { Remove-Item $Target -Force }
    Say "clide uninstalled. Restart PowerShell."
    return
}

# ---- dependency check ----
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Warn "claude not found — install Claude Code first: https://claude.com/claude-code"
    return
}
if (-not (Get-Module -ListAvailable PSReadLine)) {
    Warn "PSReadLine not available — suggest-mode buffer insert will fall back to print-only."
}

# ---- ensure an elevation helper (sudo) so clide can run admin commands ----
$haveSudo = (Get-Command sudo -ErrorAction SilentlyContinue) -or (Get-Command gsudo -ErrorAction SilentlyContinue)
if (-not $haveSudo) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say "installing gsudo (sudo for Windows) via winget…"
        winget install --id gerardog.gsudo -e --accept-source-agreements --accept-package-agreements
    } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        Say "installing gsudo via scoop…"; scoop install gsudo
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Say "installing gsudo via choco…"; choco install gsudo -y
    } else {
        Warn "no sudo/gsudo and no winget/scoop/choco to install one — admin commands won't elevate."
        Warn "  On Win11 24H2 enable Settings ▸ System ▸ For developers ▸ Sudo, or install gsudo: https://github.com/gerardog/gsudo"
    }
} else { Say "elevation helper present (sudo/gsudo)" }

# ---- install file ----
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
Say "downloading clide.ps1 from $BaseUrl"
# Fetch as text and re-write WITH a UTF-8 BOM. Windows PowerShell 5.1 decodes a BOM-less script as
# Windows-1252, which mangles clide.ps1's non-ASCII glyphs into smart quotes and breaks parsing.
$content = (Invoke-WebRequest -Uri "$BaseUrl/clide.ps1" -UseBasicParsing).Content
$content = $content.TrimStart([char]0xFEFF)               # drop any leading BOM char so we don't double it
$utf8Bom = New-Object System.Text.UTF8Encoding $true      # $true = emit BOM
[System.IO.File]::WriteAllText($Target, $content, $utf8Bom)

# ---- wire into $PROFILE (idempotent) ----
$profileText = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($profileText -and $profileText.Contains($MarkBeg)) {
    Say "already wired into `$PROFILE (left as-is)"
} else {
    Add-Content -Path $PROFILE -Value "`n$MarkBeg`n. `"$Target`"`n$MarkEnd"
    Say "added dot-source line to $PROFILE"
}

. $Target                                                # available immediately in this session
Say "done — clide installed and ready now. Try:  clide list git branches by date"
Say "(also added to your `$PROFILE for new sessions.)"
