$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$upstreamUrl = 'https://github.com/deepseek-ai/chat-demo.git'
$officialRepoPattern = '^(https://github\.com/deepseek-ai/chat-demo(?:\.git)?/?|git@github\.com:deepseek-ai/chat-demo(?:\.git)?)$'

function Invoke-Git {
  param([Parameter(Mandatory)][string[]]$GitArgs)

  Write-Host "`n> git $($GitArgs -join ' ')" -ForegroundColor DarkGray
  & git -C $repoRoot @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Git command failed (exit $LASTEXITCODE): git $($GitArgs -join ' ')"
  }
}

function Get-GitText {
  param([Parameter(Mandatory)][string[]]$GitArgs)

  $output = & git -C $repoRoot @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Git command failed (exit $LASTEXITCODE): git $($GitArgs -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}

function Test-Ancestor {
  param(
    [Parameter(Mandatory)][string]$Ancestor,
    [Parameter(Mandatory)][string]$Descendant
  )

  & git -C $repoRoot merge-base --is-ancestor $Ancestor $Descendant 2>$null
  return $LASTEXITCODE -eq 0
}

function Get-RemoteUrl {
  param([Parameter(Mandatory)][string]$Name)
  return Get-GitText -GitArgs @('remote', 'get-url', $Name)
}

function Test-Ref {
  param([Parameter(Mandatory)][string]$Name)
  & git -C $repoRoot show-ref --verify --quiet $Name 2>$null
  return $LASTEXITCODE -eq 0
}

function Test-GitPathExists {
  param([Parameter(Mandatory)][string]$GitPath)
  $path = Get-GitText -GitArgs @('rev-parse', '--git-path', $GitPath)
  if (-not [IO.Path]::IsPathRooted($path)) {
    $path = Join-Path $repoRoot $path
  }
  return Test-Path -LiteralPath $path
}

function Stop-IfOperationInProgress {
  foreach ($gitPath in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply')) {
    if (Test-GitPathExists -GitPath $gitPath) {
      throw "A Git operation is already in progress ($gitPath). Finish or abort it before running this script."
    }
  }
}

function Add-UpstreamIfNeeded {
  $remotes = ((Get-GitText -GitArgs @('remote')) -split "`n") | ForEach-Object { $_.Trim() }
  if ($remotes -notcontains 'origin') {
    throw 'The origin remote is missing. Configure origin to point to your fork first.'
  }

  $originUrl = Get-RemoteUrl -Name 'origin'
  if ($originUrl -match $officialRepoPattern) {
    throw 'origin points to the official repository. Configure origin to point to your fork; this script never pushes to upstream.'
  }

  if ($remotes -contains 'upstream') {
    $configuredUpstream = Get-RemoteUrl -Name 'upstream'
    if ($configuredUpstream -notmatch $officialRepoPattern) {
      throw "The upstream remote does not point to the official repository: $configuredUpstream"
    }
  } else {
    Write-Host "Adding upstream remote: $upstreamUrl"
    Invoke-Git -GitArgs @('remote', 'add', 'upstream', $upstreamUrl)
  }

  Write-Host "Fork (origin): $originUrl"
  Write-Host "Official (upstream): $(Get-RemoteUrl -Name 'upstream')"
}

try {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git was not found. Install Git for Windows and try again.'
  }

  $actualRoot = Get-GitText -GitArgs @('rev-parse', '--show-toplevel')
  if ([IO.Path]::GetFullPath($actualRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($repoRoot).TrimEnd('\')) {
    throw 'The script directory does not match the Git repository root.'
  }

  Stop-IfOperationInProgress
  $branch = Get-GitText -GitArgs @('branch', '--show-current')
  if ($branch -ne 'dev') {
    throw "Switch to the dev branch before running this script (current branch: '$branch')."
  }

  $status = Get-GitText -GitArgs @('status', '--porcelain')
  if ($status) {
    throw "The working tree is not clean. Commit or stash changes before syncing:`n$status"
  }

  Add-UpstreamIfNeeded

  foreach ($ref in @('refs/heads/main', 'refs/heads/dev')) {
    if (-not (Test-Ref -Name $ref)) {
      throw "Required local branch is missing: $($ref -replace '^refs/heads/', '')"
    }
  }

  Write-Host "`nFetching updates from origin and upstream..." -ForegroundColor Cyan
  Invoke-Git -GitArgs @('fetch', '--prune', 'origin')
  Invoke-Git -GitArgs @('fetch', '--prune', 'upstream')

  if (-not (Test-Ref -Name 'refs/remotes/upstream/main')) {
    throw 'The official upstream/main branch was not found.'
  }

  if (-not (Test-Ancestor -Ancestor 'main' -Descendant 'upstream/main')) {
    throw 'Local main has commits not present in upstream/main. Nothing was merged or pushed; inspect main manually.'
  }

  if (Test-Ref -Name 'refs/remotes/origin/main') {
    if (-not (Test-Ancestor -Ancestor 'origin/main' -Descendant 'upstream/main')) {
      throw 'origin/main is not behind upstream/main. Nothing was merged or pushed; inspect the fork main branch manually.'
    }
  }

  if (Test-Ref -Name 'refs/remotes/origin/dev') {
    $devCanFastForward = (Test-Ancestor -Ancestor 'origin/dev' -Descendant 'dev') -or
      (Test-Ancestor -Ancestor 'dev' -Descendant 'origin/dev')
    if (-not $devCanFastForward) {
      throw 'Local dev and origin/dev have diverged. Nothing was merged or pushed; reconcile the dev branches manually.'
    }
  }

  Write-Host "`nThis will:`n  1. Fast-forward local main to upstream/main.`n  2. Fast-forward dev from origin/dev when needed.`n  3. Merge main into dev.`n  4. Push main and dev to origin (your fork)." -ForegroundColor Yellow
  $answer = Read-Host 'Continue? [Y/N]'
  if ($answer -notmatch '(?i)^(y|yes)$') {
    Write-Host 'Cancelled. No merges or pushes were made.'
    exit 0
  }

  Write-Host "`nUpdating main..." -ForegroundColor Cyan
  Invoke-Git -GitArgs @('switch', 'main')
  Invoke-Git -GitArgs @('merge', '--ff-only', 'upstream/main')

  Write-Host "`nUpdating dev..." -ForegroundColor Cyan
  Invoke-Git -GitArgs @('switch', 'dev')
  if (Test-Ref -Name 'refs/remotes/origin/dev') {
    Invoke-Git -GitArgs @('merge', '--ff-only', 'origin/dev')
  }

  try {
    Invoke-Git -GitArgs @('merge', '--no-edit', 'main')
  } catch {
    if (Test-GitPathExists -GitPath 'MERGE_HEAD') {
      Write-Host 'A merge conflict occurred; aborting the incomplete merge to leave the working tree unchanged.' -ForegroundColor Yellow
      Invoke-Git -GitArgs @('merge', '--abort')
    }
    throw
  }

  Write-Host "`nPushing updated branches to origin..." -ForegroundColor Cyan
  Invoke-Git -GitArgs @('push', 'origin', 'main')
  Invoke-Git -GitArgs @('push', 'origin', 'dev')

  Write-Host "`nSync completed. You are on dev." -ForegroundColor Green
} catch {
  Write-Host "`nSync stopped: $($_.Exception.Message)" -ForegroundColor Red

  if (Test-GitPathExists -GitPath 'MERGE_HEAD') {
    Write-Host 'Aborting the incomplete merge...' -ForegroundColor Yellow
    & git -C $repoRoot merge --abort
  }

  $currentBranch = Get-GitText -GitArgs @('branch', '--show-current') 2>$null
  if ($currentBranch -eq 'main' -and -not (Test-GitPathExists -GitPath 'MERGE_HEAD')) {
    & git -C $repoRoot switch dev
  }

  exit 1
}
