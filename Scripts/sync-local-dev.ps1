<#
.SYNOPSIS
  Merge the fork owner's open GitHub PRs into a local integration branch.

.DESCRIPTION
  Rebuilds a local integration branch (default "local/dev") on top of the
  current upstream main, then merges every open pull request authored from the
  owner's fork into it, so the whole PR set exists in one tree that can be
  built and tested locally.

  Steps:
    1. `git fetch origin` and `git fetch upstream` (no code is changed here)
    2. Snapshot the current integration branch to `backup/local-dev-pre-merge`
    3. Reset the integration branch to `upstream/main`
    4. For each open PR authored by -ForkLogin (oldest first, via `gh api`),
       `git merge origin/<head>`
    5. On the first merge conflict the script stops. Resolve the conflict and
       run `git merge --continue`, or run `git reset --hard backup/local-dev-pre-merge`
       to restore the pre-run state.

  Requires the `gh` CLI, authenticated as the fork owner. Will not run with a
  dirty working tree.

.PARAMETER Repo
  Upstream repo whose PRs to merge. Default "tixl3d/tixl".

.PARAMETER ForkLogin
  GitHub login of the fork owner whose open PRs to merge. Default "rofoto".

.PARAMETER IntegrationBranch
  Local branch to rebuild. Default "local/dev".

.PARAMETER SkipBackup
  Do not snapshot the integration branch to backup/local-dev-pre-merge.

.EXAMPLE
  .\Scripts\sync-local-dev.ps1

.EXAMPLE
  .\Scripts\sync-local-dev.ps1 -SkipBackup
#>

[CmdletBinding()]
param(
    [string]$Repo = 'tixl3d/tixl',
    [string]$ForkLogin = 'rofoto',
    [string]$IntegrationBranch = 'local/dev',
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

function Write-ErrLine([string]$msg) { [Console]::Error.WriteLine($msg) }

# Run a native command from an array and throw on non-zero exit. PowerShell
# ignores a native command's exit code even with $ErrorActionPreference='Stop',
# so we check $LASTEXITCODE ourselves.
function Invoke-Native {
    param([string[]]$Command)
    & $Command[0] $Command[1..($Command.Count - 1)]
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $($Command -join ' ')"
    }
}

$dirty = git status --porcelain
if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    Write-ErrLine 'Working tree is not clean. Commit or stash before running:'
    $dirty -split "`r?`n" | ForEach-Object { Write-ErrLine "  $_" }
    exit 1
}

$previousBranch = git branch --show-current

Write-Host '== Fetching remotes =='
Invoke-Native @('git', 'fetch', 'origin')
Invoke-Native @('git', 'fetch', 'upstream')

Write-Host '== Rebuilding integration branch =='
if (-not $SkipBackup) {
    git rev-parse --quiet --verify "refs/heads/$IntegrationBranch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Native @('git', 'branch', '-f', 'backup/local-dev-pre-merge', $IntegrationBranch)
        Write-Host "  backed up $IntegrationBranch -> backup/local-dev-pre-merge"
    } else {
        Write-Host "  no existing $IntegrationBranch to back up (assuming fresh checkout)"
    }
} else {
    Write-Host '  -SkipBackup: leaving backup/local-dev-pre-merge untouched'
}

git rev-parse --quiet --verify "refs/heads/$IntegrationBranch" 2>$null
if ($LASTEXITCODE -eq 0) {
    Invoke-Native @('git', 'switch', '-q', $IntegrationBranch)
    Invoke-Native @('git', 'reset', '--hard', 'upstream/main')
    Write-Host "  $IntegrationBranch reset to upstream/main"
} else {
    Invoke-Native @('git', 'switch', '-c', $IntegrationBranch, 'upstream/main')
    Write-Host "  created $IntegrationBranch from upstream/main"
}

Write-Host '== Gathering open PRs =='
$raw = gh api --paginate "repos/$Repo/pulls?state=open&per_page=100" --jq '.[] | {number: .number, login: .user.login, head: .head.ref, title: .title}'
if ($LASTEXITCODE -ne 0) {
    Write-ErrLine 'gh api failed. Is `gh` installed and authenticated as the fork owner?'
    exit 1
}
$prs = @($raw | ConvertFrom-Json | Where-Object login -eq $ForkLogin | Sort-Object number)

if ($prs.Count -eq 0) {
    Write-Host "  no open PRs for $ForkLogin in $Repo"
    git switch -q $previousBranch 2>$null
    exit 0
}

foreach ($pr in $prs) {
    Write-Host "  #$($pr.number) $($pr.title) ($($pr.head))"
}

Write-Host '== Merging PRs =='
$merged = @()
foreach ($pr in $prs) {
    $headRef = "refs/remotes/origin/$($pr.head)"
    git rev-parse --quiet --verify $headRef 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  skipping PR #$($pr.number): $($pr.head) not present as origin/$($pr.head) -- run 'git fetch origin' and retry"
        continue
    }
    Write-Host "  merging PR #$($pr.number) ($($pr.head))..."
    git merge --no-edit -m "Merge PR #$($pr.number) $($pr.head) into $IntegrationBranch" "origin/$($pr.head)"
    if ($LASTEXITCODE -ne 0) {
        Write-ErrLine "Merge conflict while merging PR #$($pr.number) ($($pr.head))."
        Write-ErrLine "Resolve the conflict and run:  git merge --continue"
        Write-ErrLine "Or restore the pre-run state with:  git reset --hard backup/local-dev-pre-merge"
        exit 1
    }
    $merged += "  #$($pr.number) $($pr.head)"
}

Write-Host ''
Write-Host "Done: $($merged.Count) PR(s) merged into $IntegrationBranch"
$merged | ForEach-Object { Write-Host $_ }

if ($previousBranch) {
    git switch -q $previousBranch 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  returned to $previousBranch" }
}