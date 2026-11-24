# fenix-selected-skills.ps1 — 自选 Claude Skills 名单管理（Windows PowerShell 5.1+）
#
# 与 fenix-selected-skills.sh 功能对齐。在 macOS / Linux 上运行时会自动转交给 fenix-selected-skills.sh。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\fenix-selected-skills.ps1 <命令> [参数...]
#   list / render / refresh / sync / install / update / status / check / add / remove / env / help
#
# 依赖：Git for Windows（git）；curl.exe 可选（Win10+ 自带），否则用 .NET 下载。
# 安装目录：--target user（默认 ~/.claude/skills）、project（当前目录\.claude\skills）或任意目录。
# 状态文件：<目标目录>\.skills-manager.json。

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ScriptDir = $PSScriptRoot
$DataFile = [IO.Path]::Combine($ScriptDir, 'fenix-selected-skills.json')
$MdFile = [IO.Path]::Combine($ScriptDir, 'fenix-selected-skills.md')
$GitHub = 'https://github.com'
$TypeOrder = @('文档处理', '内容抓取', '内容创作', '前端开发', '开发流程', '工程工具', '项目管理', '浏览器自动化', '辅助增强')

$SkillsDir = $env:CLAUDE_SKILLS_DIR
if (-not $SkillsDir) { $SkillsDir = [IO.Path]::Combine([IO.Path]::Combine($HOME, '.claude'), 'skills') }
$StateFile = $env:SKILLS_STATE_FILE
if (-not $StateFile) { $StateFile = [IO.Path]::Combine($SkillsDir, '.skills-manager.json') }

$Command = 'help'
$Rest = @()
if ($args.Count -ge 1) { $Command = [string]$args[0] }
if ($args.Count -gt 1) { $Rest = @($args[1..($args.Count - 1)]) }

$OnWindows = ($env:OS -eq 'Windows_NT')
$ActuallyWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$DirSep = [IO.Path]::DirectorySeparatorChar
$NullDevice = $(if ($ActuallyWindows) { 'NUL' } else { '/dev/null' })
$CurlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $CurlCmd) {
  $c = Get-Command curl -ErrorAction SilentlyContinue
  if ($c -and $c.CommandType -eq 'Application') { $CurlCmd = $c } else { $CurlCmd = $null }
}

# 非 Windows：交给 bash 版，保持单一实现
if (-not $OnWindows) {
  $sh = [IO.Path]::Combine($ScriptDir, 'fenix-selected-skills.sh')
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ((Test-Path -LiteralPath $sh) -and $bash) {
    $all = @($Command) + $Rest
    & bash $sh @all
    exit $LASTEXITCODE
  }
  Write-Host "✗ 非 Windows 环境请使用 fenix-selected-skills.sh（未找到可用的 bash）" -ForegroundColor Red
  exit 1
}

function Write-Info($m) { Write-Host ("· " + $m) }
function Write-Ok($m) { Write-Host ("✓ " + $m) -ForegroundColor Green }
function Write-Warn($m) { Write-Host ("! " + $m) -ForegroundColor Yellow }
function Write-ErrLine($m) { Write-Host ("✗ " + $m) -ForegroundColor Red }
function Fail($m) { Write-ErrLine $m; exit 1 }

function Ensure-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $hint = '安装 git'
    if ($ActuallyWindows) { $hint = '安装 Git for Windows：https://git-scm.com/download/win' }
    Fail "缺少 git，$hint"
  }
}

function Ensure-Data {
  if (-not (Test-Path -LiteralPath $DataFile)) { Fail "找不到名单文件：$DataFile" }
}

function Read-Json($path) {
  $raw = [IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  return ($raw | ConvertFrom-Json)
}

function Save-Json($path, $obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 20
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($path, $json + "`n", $enc)
}

function Get-List { Ensure-Data; return (Read-Json $DataFile) }

function Get-Entry($data, $name) {
  return ($data.skills | Where-Object { $_.name -eq $name } | Select-Object -First 1)
}

function Format-Ver($kind, $ver) {
  $v = [string]$ver
  if ($kind -eq 'commit') {
    if ($v.Length -gt 8) { return $v.Substring(0, 8) }
    return $v
  }
  return $v
}

function Apply-Target($t) {
  if (-not $t) { Fail "--target 需要 user、project 或目录" }
  switch ([string]$t) {
    'user' {
      if ($env:CLAUDE_SKILLS_DIR) { $script:SkillsDir = $env:CLAUDE_SKILLS_DIR }
      else { $script:SkillsDir = [IO.Path]::Combine([IO.Path]::Combine($HOME, '.claude'), 'skills') }
    }
    'project' { $script:SkillsDir = [IO.Path]::Combine([IO.Path]::Combine((Get-Location).Path, '.claude'), 'skills') }
    default { $script:SkillsDir = [string]$t }
  }
  if ($env:SKILLS_STATE_FILE) { $script:StateFile = $env:SKILLS_STATE_FILE }
  else { $script:StateFile = [IO.Path]::Combine($script:SkillsDir, '.skills-manager.json') }
}

function Get-SkillName($skillMd) {
  if (-not (Test-Path -LiteralPath $skillMd)) { return $null }
  $lines = Get-Content -LiteralPath $skillMd -TotalCount 40 -Encoding UTF8
  foreach ($line in $lines) {
    if ($line -match '^name:\s*(.+)$') {
      return ($Matches[1].Trim().Trim('"').Trim("'"))
    }
  }
  return $null
}

function Get-InstalledVersion($name) {
  if (Test-Path -LiteralPath $StateFile) {
    try { $state = Read-Json $StateFile } catch { $state = $null }
    if ($state -and $state.skills) {
      $prop = $state.skills.PSObject.Properties[$name]
      if ($prop -and $prop.Value) {
        return @{ kind = [string]$prop.Value.version_kind; version = [string]$prop.Value.version }
      }
    }
  }
  $marker = [IO.Path]::Combine([IO.Path]::Combine($SkillsDir, $name), '.skill-manager.json')
  if (Test-Path -LiteralPath $marker) {
    try {
      $m = Read-Json $marker
      return @{ kind = [string]$m.version_kind; version = [string]$m.version }
    } catch { return $null }
  }
  return $null
}

function Save-StateEntry($name, $repo, $path, $ver, $kind, $now) {
  $dir = Split-Path -Parent $StateFile
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path -LiteralPath $StateFile) {
    try { $state = Read-Json $StateFile } catch { $state = $null }
  } else { $state = $null }
  if (-not $state) { $state = [pscustomobject]@{ skills = [pscustomobject]@{} } }
  if (-not $state.PSObject.Properties['skills']) {
    $state | Add-Member -NotePropertyName skills -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $entry = [pscustomobject]@{
    repo = $repo; path = $path; version = $ver; version_kind = $kind; installed_at = $now
  }
  $state.skills | Add-Member -NotePropertyName $name -NotePropertyValue $entry -Force
  Save-Json $StateFile $state
}

function Write-Marker($target, $repo, $path, $ver, $kind, $now) {
  $m = [pscustomobject]@{
    repo = $repo; path = $path; version = $ver; version_kind = $kind; installed_at = $now
  }
  Save-Json ([IO.Path]::Combine($target, '.skill-manager.json')) $m
}

function Invoke-GitCapture([string[]]$gitArgs) {
  $out = & git @gitArgs 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return @($out)
}

function Invoke-GitRun([string[]]$gitArgs) {
  $out = & git @gitArgs 2>&1 | Out-String
  return @{ Code = $LASTEXITCODE; Output = $out }
}

function Invoke-GitRetry([string[]]$gitArgs, [int]$attempts = 3, [string]$cleanDest = $null) {
  $result = $null
  for ($i = 1; $i -le $attempts; $i++) {
    if ($cleanDest) { Remove-Item -LiteralPath $cleanDest -Recurse -Force -ErrorAction SilentlyContinue }
    $result = Invoke-GitRun $gitArgs
    if ($result.Code -eq 0) { return $true }
    if ($i -lt $attempts) {
      Write-Warn "网络操作失败，重试 $i/$attempts"
      Start-Sleep -Seconds 2
    }
  }
  if ($result) { Write-Host $result.Output }
  return $false
}

function Parse-Tag($tag) {
  $m = [regex]::Match($tag, '^([A-Za-z][A-Za-z0-9._-]*-)?v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.]+))?(?:\+[0-9A-Za-z.]+)?$')
  if (-not $m.Success) { return $null }
  $pre = $m.Groups[5].Value
  $rank = 0
  if ($pre) { $rank = 1 }
  return [pscustomobject]@{
    Tag = $tag
    Major = [int]$m.Groups[2].Value
    Minor = [int]$m.Groups[3].Value
    Patch = [int]$m.Groups[4].Value
    Pre = $pre
    PreRank = $rank
  }
}

function Resolve-Version($repo) {
  $url = "$GitHub/$repo.git"
  $lines = $null
  for ($i = 1; $i -le 3; $i++) {
    $lines = Invoke-GitCapture @('ls-remote', '--tags', '--refs', $url)
    if ($null -ne $lines) { break }
    if ($i -lt 3) { Start-Sleep -Seconds 2 }
  }
  $parsed = @()
  if ($lines) {
    foreach ($line in $lines) {
      if ($line -match 'refs/tags/(.+)$') {
        $p = Parse-Tag $Matches[1]
        if ($p) { $parsed += $p }
      }
    }
  }
  if ($parsed.Count -gt 0) {
    $best = $parsed | Sort-Object Major, Minor, Patch, PreRank, Pre | Select-Object -Last 1
    return @{ kind = 'tag'; version = $best.Tag }
  }
  $headLines = @()
  for ($i = 1; $i -le 3; $i++) {
    $captured = Invoke-GitCapture @('ls-remote', $url, 'HEAD')
    if ($null -ne $captured) { $headLines = @($captured); break }
    if ($i -lt 3) { Start-Sleep -Seconds 2 }
  }
  if ($headLines.Count -eq 0) { return $null }
  $sha = ([string]$headLines[0] -split '\s+')[0]
  if (-not $sha) { return $null }
  return @{ kind = 'commit'; version = $sha }
}

function Fetch-Repo($repo, $ver, $kind, $dest, $path) {
  $sparse = $false
  if ($path -and $path -ne '.') { $sparse = $true }
  if ($kind -eq 'tag') {
    $cloneArgs = @('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1')
    if ($sparse) { $cloneArgs += @('--filter=blob:none', '--sparse') }
    $cloneArgs += @('--branch', $ver, "$GitHub/$repo.git", $dest)
    if (-not (Invoke-GitRetry $cloneArgs 3 $dest)) { return $false }
    if ($sparse) {
      if (-not (Invoke-GitRetry @('-C', $dest, 'sparse-checkout', 'set', '--no-cone', "$path/") 2)) { return $false }
    }
  } else {
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    & git init --quiet $dest | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    & git -C $dest remote add origin "$GitHub/$repo.git" | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $fetchArgs = @('-C', $dest, 'fetch', '--quiet', '--depth', '1')
    if ($sparse) {
      & git -C $dest config remote.origin.promisor true | Out-Null
      & git -C $dest config remote.origin.partialclonefilter blob:none | Out-Null
      & git -C $dest sparse-checkout init --no-cone 2>$null | Out-Null
      $sparseFile = [IO.Path]::Combine([IO.Path]::Combine([IO.Path]::Combine($dest, '.git'), 'info'), 'sparse-checkout')
      [IO.File]::WriteAllText($sparseFile, "$path/`n", (New-Object System.Text.UTF8Encoding($false)))
      $fetchArgs += '--filter=blob:none'
    }
    $fetchArgs += @('origin', $ver)
    if (-not (Invoke-GitRetry $fetchArgs 3)) { return $false }
    if (-not (Invoke-GitRetry @('-c', 'advice.detachedHead=false', '-C', $dest, 'checkout', '--quiet', 'FETCH_HEAD') 2)) { return $false }
  }
  return $true
}

function Get-RemoteSkillMd($repo, $ver, $path, $outFile) {
  $apiPath = 'SKILL.md'
  if ($path -and $path -ne '.') { $apiPath = "$path/SKILL.md" }
  $raw = "https://raw.githubusercontent.com/$repo/$ver/$apiPath"
  $api = "https://api.github.com/repos/$repo/contents/$apiPath?ref=$ver"
  if ($script:CurlCmd) {
    & $script:CurlCmd.Source -fsS --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 15 -o $outFile $raw 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
  }
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'fenix-selected-skills.ps1')
    $wc.DownloadFile($raw, $outFile)
    return $true
  } catch { }
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'fenix-selected-skills.ps1')
    $wc.Headers.Add('Accept', 'application/vnd.github.raw')
    $wc.DownloadFile($api, $outFile)
    return $true
  } catch { }
  return $false
}

function Install-One($name, [bool]$force = $false, [bool]$backup = $false) {
  if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail "名称不合法：$name（只允许小写字母、数字、连字符）" }
  $data = Get-List
  $entry = Get-Entry $data $name
  if (-not $entry) { Fail "名单中没有「$name」" }
  if (-not (Test-Path -LiteralPath $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }

  $path = [string]$entry.path
  if ($path -and ($path.StartsWith('/') -or $path -match '(^|/)\.\.(/|$)')) { Fail "$name：path 不合法（$path）" }
  if (-not $entry.version) { Write-ErrLine "$name：版本为空，先运行 refresh $name"; return $false }
  if (-not $entry.repo -or $entry.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "$name：repo 不合法（$($entry.repo)）" }
  if (-not $path -or $path -eq '.') { Write-Warn "$name：技能位于仓库根目录，无法只取子目录，将下载整个仓库" }

  $target = [IO.Path]::Combine($SkillsDir, $name)
  $managed = ($null -ne (Get-InstalledVersion $name))
  if (Test-Path -LiteralPath $target) {
    if ($managed) {
      Remove-Item -LiteralPath $target -Recurse -Force
    } elseif ($force) {
      if ($backup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backupDir = [IO.Path]::Combine([IO.Path]::Combine($SkillsDir, '.backups'), "$name-$stamp")
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupDir) -Force | Out-Null
        Move-Item -LiteralPath $target -Destination $backupDir
        Write-Warn "$name：已备份原目录到 $backupDir"
      } else {
        Write-Warn "$name：覆盖非本工具管理的目录 $target"
        Remove-Item -LiteralPath $target -Recurse -Force
      }
    } else {
      Write-Warn "$name：$target 已存在且不是本工具安装，跳过（--force 可覆盖）"
      return $true
    }
  }

  $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('claude-skill-' + [guid]::NewGuid().ToString('N')))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    Write-Info "$name：下载 $($entry.repo)@$(Format-Ver $entry.version_kind $entry.version)"
    $repoDir = [IO.Path]::Combine($tmp, 'repo')
    if (-not (Fetch-Repo $entry.repo $entry.version $entry.version_kind $repoDir $path)) {
      Write-ErrLine "$name：下载失败（$($entry.repo)@$(Format-Ver $entry.version_kind $entry.version)）"
      return $false
    }
    $src = $repoDir
    if ($path -and $path -ne '.') { $src = [IO.Path]::Combine($repoDir, $path.Replace('/', $DirSep)) }
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($src, 'SKILL.md')))) {
      Write-ErrLine "$name：下载内容缺少 SKILL.md，请检查 path（当前：$path）"
      return $false
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    if ($path -and $path -ne '.') {
      Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
      }
    } else {
      Get-ChildItem -LiteralPath $repoDir -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
      }
    }
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
    Save-StateEntry $name $entry.repo $path $entry.version $entry.version_kind $now
    Write-Marker $target $entry.repo $path $entry.version $entry.version_kind $now
    Write-Ok "$name 已安装到 $target（$(Format-Ver $entry.version_kind $entry.version)）"
    return $true
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Update-EntryVersion($data, $name, $ver, $kind, $now) {
  $entry = Get-Entry $data $name
  if ($entry) {
    $entry.version = $ver
    $entry.version_kind = $kind
    $entry.checked_at = $now
  }
}

function Sync-One($name, [bool]$force = $false, [bool]$dry = $false) {
  $data = Get-List
  $entry = Get-Entry $data $name
  if (-not $entry) { Write-Warn "$name 不在名单中，跳过"; return }
  $latest = Resolve-Version ([string]$entry.repo)
  if (-not $latest) { Write-Warn "$name：查询 $($entry.repo) 失败，跳过"; return }
  $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
  Update-EntryVersion $data $name $latest.version $latest.kind $now
  Save-Json $DataFile $data

  $target = [IO.Path]::Combine($SkillsDir, $name)
  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    if ($dry) { Write-Info "[dry-run] $name：将安装 $(Format-Ver $latest.kind $latest.version)" }
    else {
      Write-Info "$name：未安装，安装最新版"
      Install-One $name $false $false | Out-Null
    }
    return
  }

  $skillMd = [IO.Path]::Combine($target, 'SKILL.md')
  $missingMd = $false
  if (-not (Test-Path -LiteralPath $skillMd)) { Write-Warn "$name：$target 缺少 SKILL.md，按待更新处理"; $missingMd = $true }
  $sname = Get-SkillName $skillMd
  if ($sname -and $sname -ne $name) { Write-Warn "$name：目录名与 SKILL.md 的 name（$sname）不一致" }

  $inst = Get-InstalledVersion $name
  if ($inst) {
    if ($inst.version -eq $latest.version -and $inst.kind -eq $latest.kind -and -not $missingMd) {
      Write-Ok "$name 已是最新（$(Format-Ver $latest.kind $latest.version)）"
    } elseif ($dry) {
      Write-Info "[dry-run] $name：$(Format-Ver $inst.kind $inst.version) → $(Format-Ver $latest.kind $latest.version)"
    } else {
      Write-Info "$name：$(Format-Ver $inst.kind $inst.version) → $(Format-Ver $latest.kind $latest.version)"
      Install-One $name $true $false | Out-Null
    }
    return
  }

  $tmpMd = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('skill-md-' + [guid]::NewGuid().ToString('N') + '.md'))
  try {
    if (Get-RemoteSkillMd ([string]$entry.repo) $latest.version ([string]$entry.path) $tmpMd) {
      $same = $false
      try {
        $same = ((Get-FileHash -LiteralPath $tmpMd -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $skillMd -Algorithm SHA256).Hash)
      } catch { $same = $false }
      if ($same) {
        Write-Ok "$name 已存在且内容与最新版一致，纳入管理"
        if (-not $dry) {
          Save-StateEntry $name ([string]$entry.repo) ([string]$entry.path) $latest.version $latest.kind $now
          Write-Marker $target ([string]$entry.repo) ([string]$entry.path) $latest.version $latest.kind $now
        }
      } elseif ($dry) {
        Write-Info "[dry-run] $name：已存在但内容不同，将备份并更新"
      } else {
        Write-Info "$name：已存在但内容与最新版不同，备份后更新"
        Install-One $name $true $true | Out-Null
      }
    } elseif ($force) {
      if ($dry) { Write-Info "[dry-run] $name：无法校验远端内容，将备份并更新" }
      else {
        Write-Warn "$name：无法校验远端内容，按 --force 备份后更新"
        Install-One $name $true $true | Out-Null
      }
    } else {
      Write-Warn "$name：已存在但无法获取远端 SKILL.md 校验，跳过（--force 可备份并更新）"
    }
  } finally {
    Remove-Item -LiteralPath $tmpMd -Force -ErrorAction SilentlyContinue
  }
}

function Get-ManagedNames {
  if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
  try { $state = Read-Json $StateFile } catch { return @() }
  if (-not $state.skills) { return @() }
  return @($state.skills.PSObject.Properties.Name)
}

function Render-Lines {
  $data = Get-List
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# 自选 Claude Skills 名单')
  $lines.Add('')
  $lines.Add('> 本文件由名单脚本（`fenix-selected-skills.sh` / `fenix-selected-skills.ps1`）从 [fenix-selected-skills.json](fenix-selected-skills.json) 自动生成，请勿手改。')
  foreach ($n in @($data.notes)) {
    if ($n) { $lines.Add("> $n") }
  }
  $lines.Add('')
  $lines.Add("共 $(@($data.skills).Count) 项 · 更新于 $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
  $lines.Add('')
  $lines.Add('| 类型 | 名称 | GitHub | 仓库路径 | 最新版本 | 说明 |')
  $lines.Add('| --- | --- | --- | --- | --- | --- |')
  $rows = $data.skills | Sort-Object @{ Expression = {
      $idx = $TypeOrder.IndexOf([string]$_.type)
      if ($idx -lt 0) { 99 } else { $idx }
    } }, @{ Expression = { [string]$_.name } }
  foreach ($s in $rows) {
    $p = [string]$s.path
    if (-not $p -or $p -eq '.') { $p = '—' }
    $lines.Add("| $($s.type) | $($s.name) | [$($s.repo)]($GitHub/$($s.repo)) | $p | $(Format-Ver $s.version_kind $s.version) | $($s.description) |")
  }
  $lines.Add('')
  $lines.Add('同步：`fenix-selected-skills.sh sync`（Windows：`fenix-selected-skills.ps1 sync`） · 查状态：`fenix-selected-skills.sh status` · 帮助：`fenix-selected-skills.sh help`')
  return $lines
}

function Cmd-List {
  foreach ($line in (Render-Lines)) { Write-Output $line }
}

function Cmd-Render {
  $lines = Render-Lines
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($MdFile, (($lines -join "`n") + "`n"), $enc)
  Write-Ok "已生成 $MdFile"
}

function Cmd-Refresh($names) {
  $data = Get-List
  if (-not $names -or $names.Count -eq 0) { $names = @($data.skills | ForEach-Object { $_.name }) }
  $cache = @{}
  foreach ($name in $names) {
    $entry = Get-Entry $data $name
    if (-not $entry) { Write-Warn "$name 不在名单中，跳过"; continue }
    $repo = [string]$entry.repo
    if (-not $cache.ContainsKey($repo)) { $cache[$repo] = Resolve-Version $repo }
    $latest = $cache[$repo]
    if (-not $latest) { Write-Warn "$name：查询 $repo 失败（网络或仓库不存在）"; continue }
    Update-EntryVersion $data $name $latest.version $latest.kind (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Write-Ok "$name：$(Format-Ver $latest.kind $latest.version)"
  }
  $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
  Save-Json $DataFile $data
  Cmd-Render
}

function Cmd-Install([string[]]$names, [bool]$force = $false) {
  $data = Get-List
  if (-not $names -or $names.Count -eq 0) { $names = @($data.skills | ForEach-Object { $_.name }) }
  foreach ($name in $names) { Install-One $name $force $false | Out-Null }
}

function Cmd-Sync([string[]]$names, [bool]$force = $false, [bool]$dry = $false) {
  $data = Get-List
  if (-not $names -or $names.Count -eq 0) { $names = @($data.skills | ForEach-Object { $_.name }) }
  Write-Info "目标目录：$SkillsDir"
  foreach ($name in $names) { Sync-One $name $force $dry }
  $data = Get-List
  $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
  Save-Json $DataFile $data
  if ($dry) { Write-Info "dry-run 结束，未改动文件" }
  else { Cmd-Render }
}

function Cmd-Update([string[]]$names) {
  $data = Get-List
  if (-not $names -or $names.Count -eq 0) { $names = Get-ManagedNames }
  if (-not $names -or $names.Count -eq 0) { Fail "还没有安装记录，先运行 fenix-selected-skills.ps1 sync 或 install" }
  $cache = @{}
  foreach ($name in $names) {
    $entry = Get-Entry $data $name
    if (-not $entry) { Write-Warn "$name 不在名单中，跳过"; continue }
    $repo = [string]$entry.repo
    if (-not $cache.ContainsKey($repo)) { $cache[$repo] = Resolve-Version $repo }
    $latest = $cache[$repo]
    if (-not $latest) { Write-Warn "$name：查询 $repo 失败，跳过"; continue }
    $inst = Get-InstalledVersion $name
    if (-not $inst) { Write-Warn "$name 尚未安装或没有版本记录，跳过（用 sync）"; continue }
    Update-EntryVersion $data $name $latest.version $latest.kind (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Save-Json $DataFile $data
    if ($inst.version -eq $latest.version -and $inst.kind -eq $latest.kind) {
      Write-Ok "$name 已是最新（$(Format-Ver $latest.kind $latest.version)）"
    } else {
      Write-Info "$name：$(Format-Ver $inst.kind $inst.version) → $(Format-Ver $latest.kind $latest.version)"
      Install-One $name $true $false | Out-Null
    }
  }
  $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
  Save-Json $DataFile $data
  Cmd-Render
}

function Cmd-Status {
  $data = Get-List
  Write-Info "目标目录：$SkillsDir"
  Write-Output ("{0,-30} {1,-12} {2,-12} {3}" -f '名称', '已安装', '最新', '状态')
  foreach ($s in $data.skills) {
    $inst = Get-InstalledVersion ([string]$s.name)
    $instText = '-'
    if ($inst) { $instText = Format-Ver $inst.kind $inst.version }
    $latestText = Format-Ver $s.version_kind $s.version
    if ($instText -eq '-') { $st = '未安装' }
    elseif ($instText -eq $latestText) { $st = '已最新' }
    else { $st = '可更新' }
    Write-Output ("{0,-30} {1,-12} {2,-12} {3}" -f $s.name, $instText, $latestText, $st)
  }
}

function Get-RemoteCode($repo, $ver, $path) {
  $apiPath = 'SKILL.md'
  if ($path -and $path -ne '.') { $apiPath = "$path/SKILL.md" }
  $raw = "https://raw.githubusercontent.com/$repo/$ver/$apiPath"
  $api = "https://api.github.com/repos/$repo/contents/$apiPath?ref=$ver"
  if ($script:CurlCmd) {
    $code = & $script:CurlCmd.Source -sS -o $script:NullDevice -w '%{http_code}' --connect-timeout 4 --max-time 10 --retry 1 --retry-delay 1 $raw 2>$null
    if ($code -eq '200') { return '200' }
  } else {
    try {
      $wc = New-Object System.Net.WebClient
      $wc.Headers.Add('User-Agent', 'fenix-selected-skills.ps1')
      $tmp = [IO.Path]::GetTempPath() + [guid]::NewGuid().ToString('N')
      $wc.DownloadFile($raw, $tmp)
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      return '200'
    } catch { }
  }
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    & gh api "repos/$repo/contents/$apiPath?ref=$ver" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return '200' }
  }
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'fenix-selected-skills.ps1')
    $wc.Headers.Add('Accept', 'application/vnd.github+json')
    $tmp = [IO.Path]::GetTempPath() + [guid]::NewGuid().ToString('N')
    $wc.DownloadFile($api, $tmp)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return '200'
  } catch { }
  return '000'
}

function Cmd-Check([bool]$network = $false) {
  $data = Get-List
  if (-not $data.skills -or @($data.skills).Count -eq 0) { Fail "fenix-selected-skills.json 结构错误：skills 必须是非空数组" }
  $errors = 0
  $netFail = 0
  $dups = @($data.skills | Group-Object name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  if ($dups.Count -gt 0) { Write-ErrLine "重复名称：$($dups -join ' ')"; $errors++ }

  foreach ($s in $data.skills) {
    $name = [string]$s.name
    if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') { Write-ErrLine "名称不合法（需小写字母/数字/连字符）：$name"; $errors++ }
    if (-not $s.type) { Write-ErrLine "$name：type 为空"; $errors++ }
    if ([string]$s.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Write-ErrLine "$name：repo 需为 owner/name（当前：$($s.repo)）"; $errors++ }
    $path = [string]$s.path
    if ($path -and ($path.StartsWith('/') -or $path -match '(^|/)\.\.(/|$)')) { Write-ErrLine "$name：path 不合法（$path）"; $errors++ }
    if (-not $s.version) { Write-ErrLine "$name：version 为空（先运行 refresh $name）"; $errors++ }
    if ($s.version_kind -ne 'tag' -and $s.version_kind -ne 'commit') { Write-ErrLine "$name：version_kind 只能是 tag 或 commit（当前：$($s.version_kind)）"; $errors++ }
    if ($network) {
      $code = Get-RemoteCode ([string]$s.repo) ([string]$s.version) $path
      if ($code -eq '000') { Write-Warn "$name：远端未验证（网络不可达）"; $netFail++ }
      elseif ($code -ne '200') { Write-ErrLine "$name：远端 SKILL.md 不可访问（HTTP $code）"; $errors++ }
    }
  }
  if ($network) {
    if ($netFail -gt 0) { Write-Warn "$netFail 项因网络不可达未验证" }
    elseif ($errors -eq 0) { Write-Ok "远端检查通过：$(@($data.skills).Count) 项均可访问" }
  }
  if ($errors -gt 0) { Fail "检查未通过：$errors 处问题" }
  Write-Ok "检查通过：$(@($data.skills).Count) 项，字段与路径格式正常"
}

function Cmd-Add($opts) {
  $name = $opts['name']; $type = $opts['type']; $repo = $opts['repo']
  $path = $opts['path']; $desc = $opts['desc']
  if (-not $path) { $path = '.' }
  if (-not $name -or -not $type -or -not $repo) { Fail "add 需要 --name、--type、--repo" }
  if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail "名称不合法：$name" }
  if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "repo 不合法：$repo（需 owner/name）" }
  if ($path.StartsWith('/') -or $path -match '(^|/)\.\.(/|$)') { Fail "path 不合法：$path" }
  $data = Get-List
  if (Get-Entry $data $name) { Fail "名单中已有「$name」" }
  $entry = [pscustomobject]@{
    type = $type; name = $name; repo = $repo; path = $path
    version = ''; version_kind = 'commit'; description = $desc; checked_at = ''
  }
  $data.skills = @($data.skills) + $entry
  Save-Json $DataFile $data
  Write-Ok "已添加 $name"
  if ($opts['noRefresh']) { Cmd-Render }
  else { Cmd-Refresh @($name) }
}

function Cmd-Remove($name) {
  $data = Get-List
  if (-not (Get-Entry $data $name)) { Fail "名单中没有「$name」" }
  $data.skills = @($data.skills | Where-Object { $_.name -ne $name })
  Save-Json $DataFile $data
  Write-Ok "已从名单移除 $name（已安装目录 $([IO.Path]::Combine($SkillsDir,$name)) 未删除）"
  Cmd-Render
}

function Cmd-Env {
  Write-Output "平台：$([Environment]::OSVersion.VersionString)"
  Write-Output "PowerShell：$($PSVersionTable.PSVersion)"
  Write-Output "进程架构：$env:PROCESSOR_ARCHITECTURE"
  Write-Output "Windows：$OnWindows"
  Write-Output "目标目录：$SkillsDir"
  Write-Output "状态文件：$StateFile"
  Write-Output "脚本：$([IO.Path]::Combine($ScriptDir, 'fenix-selected-skills.ps1'))"
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) { Write-Output "git：$(& git --version)" } else { Write-Output "git：未安装" }
  if ($script:CurlCmd) { Write-Output "curl：$(& $script:CurlCmd.Source --version | Select-Object -First 1)" } else { Write-Output "curl：无（使用 .NET 下载）" }
  if (-not $OnWindows) { Write-Output "提示：非 Windows 环境会自动转交 fenix-selected-skills.sh 执行" }
}

function Cmd-Help {
  @'
自选 Claude Skills 名单管理（Windows PowerShell 版）

用法：
  .\fenix-selected-skills.ps1 sync [名称...] [--dry-run] [--force] [--target user|project|目录]
                                        对齐安装：缺失则装、已装则比对版本并更新（推荐）
  .\fenix-selected-skills.ps1 install [名称...] [--force] [--target ...]
                                        按名单当前版本安装，默认跳过非托管同名目录
  .\fenix-selected-skills.ps1 update [名称...] [--target ...]
                                        已安装项有新版则重装
  .\fenix-selected-skills.ps1 status [--target ...]    安装状态与最新版本
  .\fenix-selected-skills.ps1 list                     打印名单表格
  .\fenix-selected-skills.ps1 render                   重新生成 fenix-selected-skills.md
  .\fenix-selected-skills.ps1 refresh [名称...]         查询并写回最新版本（默认全部）
  .\fenix-selected-skills.ps1 check [--network]        校验名单；--network 验证远端 SKILL.md
  .\fenix-selected-skills.ps1 add --name N --type T --repo O/R [--path P] [--desc D]
  .\fenix-selected-skills.ps1 remove <名称>
  .\fenix-selected-skills.ps1 env                      打印环境信息

目标目录：
  --target user（默认 ~\.claude\skills）
  --target project（当前目录\.claude\skills）
  --target <目录>
  状态文件：<目标目录>\.skills-manager.json

示例：
  .\fenix-selected-skills.ps1 sync
  .\fenix-selected-skills.ps1 sync docx pdf --dry-run
  .\fenix-selected-skills.ps1 sync --target project
  .\fenix-selected-skills.ps1 check --network

说明：
  安装只拉取 skills[].path 对应的子目录（blobless + sparse checkout），不下载整个仓库。
  更新非本工具安装的同名目录前会备份到 <目标目录>\.backups\。
  在 macOS / Linux 上运行本脚本会自动转交 fenix-selected-skills.sh。
'@ | Write-Output
}

# ---------------- 参数解析 ----------------

function Split-CommonArgs([string[]]$inputArgs) {
  $names = @()
  $opts = @{ force = $false; dry = $false; network = $false; target = $null; noRefresh = $false }
  $i = 0
  while ($i -lt $inputArgs.Count) {
    $a = [string]$inputArgs[$i]
    switch -Regex ($a) {
      '^--force$|^-f$' { $opts.force = $true; $i++; break }
      '^--dry-run$|^-n$' { $opts.dry = $true; $i++; break }
      '^--network$' { $opts.network = $true; $i++; break }
      '^--no-refresh$' { $opts.noRefresh = $true; $i++; break }
      '^--target$' {
        if ($i + 1 -ge $inputArgs.Count) { Fail "--target 需要参数" }
        $opts.target = [string]$inputArgs[$i + 1]; $i += 2; break
      }
      '^--target=(.+)$' { $opts.target = $Matches[1]; $i++; break }
      '^-' { Fail "未知参数：$a"; break }
      default { $names += $a; $i++; break }
    }
  }
  return @{ names = $names; opts = $opts }
}

function Parse-NamedArgs([string[]]$inputArgs) {
  $opts = @{ name = $null; type = $null; repo = $null; path = $null; desc = $null; noRefresh = $false }
  $i = 0
  while ($i -lt $inputArgs.Count) {
    $a = [string]$inputArgs[$i]
    switch -Regex ($a) {
      '^--name$' { $opts.name = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--type$' { $opts.type = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--repo$' { $opts.repo = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--path$' { $opts.path = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--desc$' { $opts.desc = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--no-refresh$' { $opts.noRefresh = $true; $i++; break }
      default { Fail "未知参数：$a"; break }
    }
  }
  return $opts
}

# ---------------- 入口 ----------------

try {
  switch ($Command.ToLowerInvariant()) {
    'help' { Cmd-Help }
    { $_ -in @('-h', '--help') } { Cmd-Help }
    'env' { Cmd-Env }
    'list' { Ensure-Data; Cmd-List }
    'render' { Ensure-Data; Cmd-Render }
    'refresh' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Refresh $p.names
    }
    'sync' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Sync $p.names $p.opts.force $p.opts.dry
    }
    'install' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Install $p.names $p.opts.force
    }
    'update' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Update $p.names
    }
    'status' {
      Ensure-Data
      $p = Split-CommonArgs $Rest
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Status
    }
    'check' {
      Ensure-Data
      $p = Split-CommonArgs $Rest
      Cmd-Check $p.opts.network
    }
    'add' {
      Ensure-Git; Ensure-Data
      $opts = Parse-NamedArgs $Rest
      Cmd-Add $opts
    }
    'remove' {
      Ensure-Data
      if ($Rest.Count -ne 1) { Fail "用法：.\fenix-selected-skills.ps1 remove <名称>" }
      Cmd-Remove ([string]$Rest[0])
    }
    default { Fail "未知命令：$Command（运行 .\fenix-selected-skills.ps1 help）" }
  }
} catch {
  Write-ErrLine $_.Exception.Message
  exit 1
}
