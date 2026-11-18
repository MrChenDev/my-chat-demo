$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$upstreamUrl = 'https://github.com/deepseek-ai/chat-demo.git'
$officialRepoPattern = '^(https://github\.com/deepseek-ai/chat-demo(?:\.git)?/?|git@github\.com:deepseek-ai/chat-demo(?:\.git)?)$'

function Invoke-Git {
  param([Parameter(Mandatory)][string[]]$GitArgs)

  Write-Host "`n执行 Git 命令：git $($GitArgs -join ' ')" -ForegroundColor DarkGray
  & git -C $repoRoot @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Git 命令执行失败（退出码 $LASTEXITCODE）：git $($GitArgs -join ' ')"
  }
}

function Invoke-GitWithRetry {
  param(
    [Parameter(Mandatory)][string[]]$GitArgs,
    [int]$Attempts = 3
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      Invoke-Git -GitArgs $GitArgs
      return
    } catch {
      if ($attempt -eq $Attempts) {
        throw
      }
      $delay = 2 * $attempt
      Write-Host "Git 获取失败（第 $attempt/$Attempts 次），将在 $delay 秒后重试……" -ForegroundColor Yellow
      Start-Sleep -Seconds $delay
    }
  }
}

function Get-GitText {
  param([Parameter(Mandatory)][string[]]$GitArgs)

  $output = & git -C $repoRoot @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Git 命令执行失败（退出码 $LASTEXITCODE）：git $($GitArgs -join ' ')`n$($output -join "`n")"
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
      throw "检测到 Git 操作尚未完成（$gitPath）。请先完成或中止该操作，再运行同步脚本。"
    }
  }
}

function Add-UpstreamIfNeeded {
  $remotes = ((Get-GitText -GitArgs @('remote')) -split "`n") | ForEach-Object { $_.Trim() }
  if ($remotes -notcontains 'origin') {
    throw '缺少 origin 远端。请先将 origin 配置为指向你自己的 fork。'
  }

  $originUrl = Get-RemoteUrl -Name 'origin'
  if ($originUrl -match $officialRepoPattern) {
    throw 'origin 指向官方仓库。请将 origin 改为你自己的 fork；本脚本不会向 upstream 推送。'
  }

  if ($remotes -contains 'upstream') {
    $configuredUpstream = Get-RemoteUrl -Name 'upstream'
    if ($configuredUpstream -notmatch $officialRepoPattern) {
      throw 'upstream 远端没有指向 DeepSeek 官方仓库。请检查远端配置。'
    }
  } else {
    Write-Host "正在添加官方 upstream 远端：$upstreamUrl"
    Invoke-Git -GitArgs @('remote', 'add', 'upstream', $upstreamUrl)
  }

  Write-Host 'Fork 远端（origin）：已配置'
  Write-Host '官方远端（upstream）：已配置'
}

try {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw '未找到 Git。请安装 Git for Windows 后重试。'
  }

  $actualRoot = Get-GitText -GitArgs @('rev-parse', '--show-toplevel')
  if ([IO.Path]::GetFullPath($actualRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($repoRoot).TrimEnd('\')) {
    throw '脚本所在目录与 Git 仓库根目录不匹配。'
  }

  Stop-IfOperationInProgress
  $branch = Get-GitText -GitArgs @('branch', '--show-current')
  if ($branch -ne 'dev') {
    throw "请先切换到 dev 分支再运行脚本（当前分支：'$branch'）。"
  }

  $status = Get-GitText -GitArgs @('status', '--porcelain')
  if ($status) {
    throw "工作区存在未提交改动。请先提交或 stash 后再同步：`n$status"
  }

  Add-UpstreamIfNeeded

  foreach ($ref in @('refs/heads/main', 'refs/heads/dev')) {
    if (-not (Test-Ref -Name $ref)) {
      throw "缺少必需的本地分支：$($ref -replace '^refs/heads/', '')"
    }
  }

  Write-Host "`n正在从 origin 和 upstream 获取更新……" -ForegroundColor Cyan
  Invoke-GitWithRetry -GitArgs @('fetch', '--prune', 'origin')
  Invoke-GitWithRetry -GitArgs @('fetch', '--prune', 'upstream')

  if (-not (Test-Ref -Name 'refs/remotes/upstream/main')) {
    throw '未找到官方 upstream/main 分支。'
  }

  if (-not (Test-Ancestor -Ancestor 'main' -Descendant 'upstream/main')) {
    throw '本地 main 含有 upstream/main 中没有的提交。未执行合并或推送，请手动检查 main。'
  }

  if (Test-Ref -Name 'refs/remotes/origin/main') {
    if (-not (Test-Ancestor -Ancestor 'origin/main' -Descendant 'upstream/main')) {
      throw 'origin/main 并非落后于 upstream/main。未执行合并或推送，请手动检查 fork 的 main 分支。'
    }
  }

  if (Test-Ref -Name 'refs/remotes/origin/dev') {
    $devCanFastForward = (Test-Ancestor -Ancestor 'origin/dev' -Descendant 'dev') -or
      (Test-Ancestor -Ancestor 'dev' -Descendant 'origin/dev')
    if (-not $devCanFastForward) {
      throw '本地 dev 与 origin/dev 已分叉。未执行合并或推送，请先手动协调两个 dev 分支。'
    }
  }

  Write-Host "`n即将执行以下操作：`n  1. 将本地 main 快进到 upstream/main。`n  2. 如有需要，将 origin/dev 快进合并到本地 dev。`n  3. 将 main 合并到 dev。`n  4. 将 main 和 dev 推送到 origin（你的 fork）。" -ForegroundColor Yellow
  $answer = Read-Host '是否继续？输入 y 或“是”确认 [y/N]'
  if ($answer -notmatch '(?i)^(y|yes|是|继续)$') {
    Write-Host '已取消，未执行合并或推送。'
    exit 0
  }

  Write-Host "`n正在更新 main……" -ForegroundColor Cyan
  Invoke-Git -GitArgs @('switch', 'main')
  Invoke-Git -GitArgs @('merge', '--ff-only', 'upstream/main')

  Write-Host "`n正在更新 dev……" -ForegroundColor Cyan
  Invoke-Git -GitArgs @('switch', 'dev')
  if (Test-Ref -Name 'refs/remotes/origin/dev') {
    Invoke-Git -GitArgs @('merge', '--ff-only', 'origin/dev')
  }

  try {
    Invoke-Git -GitArgs @('merge', '--no-edit', 'main')
  } catch {
    if (Test-GitPathExists -GitPath 'MERGE_HEAD') {
      Write-Host '检测到合并冲突，正在中止本次未完成的合并，以恢复运行前的工作区。' -ForegroundColor Yellow
      Invoke-Git -GitArgs @('merge', '--abort')
    }
    throw
  }

  Write-Host "`n正在将更新后的分支推送到 origin……" -ForegroundColor Cyan
  Invoke-Git -GitArgs @('push', 'origin', 'main')
  Invoke-Git -GitArgs @('push', 'origin', 'dev')

  Write-Host "`n同步完成，当前位于 dev 分支。" -ForegroundColor Green
} catch {
  Write-Host "`n同步已停止：$($_.Exception.Message)" -ForegroundColor Red

  if (Test-GitPathExists -GitPath 'MERGE_HEAD') {
    Write-Host '正在中止尚未完成的合并……' -ForegroundColor Yellow
    & git -C $repoRoot merge --abort
  }

  $currentBranch = Get-GitText -GitArgs @('branch', '--show-current') 2>$null
  if ($currentBranch -eq 'main' -and -not (Test-GitPathExists -GitPath 'MERGE_HEAD')) {
    & git -C $repoRoot switch dev
  }

  exit 1
}
