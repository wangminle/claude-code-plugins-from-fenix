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
# 仓库私有或不存在时禁止 git 在终端等待账号密码（脚本场景直接失败而不是卡住）。
$env:GIT_TERMINAL_PROMPT = '0'

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
  try { $data = Read-Json $DataFile } catch { Fail "名单文件格式错误：$DataFile" }
  if ($null -eq $data -or -not $data.PSObject.Properties['skills'] -or $data.skills -isnot [array]) {
    Fail "名单文件结构错误：$DataFile（skills 必须是对象数组，字段必须是字符串）"
  }
  foreach ($s in $data.skills) {
    if ($s -isnot [System.Management.Automation.PSCustomObject]) {
      Fail "名单文件结构错误：$DataFile（skills 必须是对象数组，字段必须是字符串）"
    }
    foreach ($key in @('name', 'type', 'repo', 'path', 'version', 'version_kind', 'description')) {
      if ($s.PSObject.Properties[$key] -and $null -ne $s.$key -and $s.$key -isnot [string]) {
        Fail "名单文件结构错误：$DataFile（字段 $key 必须是字符串）"
      }
    }
  }
}

function Read-Json($path) {
  $raw = [IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  return ($raw | ConvertFrom-Json)
}

function Resolve-FullPath($path) {
  # 相对路径按 PowerShell 当前位置解析，避免依赖 .NET 的进程当前目录
  $p = [string]$path
  if (-not $p) { return $p }
  if ([IO.Path]::IsPathRooted($p)) { return $p }
  return [IO.Path]::Combine((Get-Location).Path, $p)
}

function Get-ParentDir($path) {
  # 裸文件名（如 SKILLS_STATE_FILE=state.json）时退回当前目录，避免空串传给 Test-Path
  $full = Resolve-FullPath $path
  $dir = [IO.Path]::GetDirectoryName($full)
  if (-not $dir) { $dir = (Get-Location).Path }
  return $dir
}

function Save-TextFile($path, $text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $full = Resolve-FullPath $path
  $dir = Get-ParentDir $full
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $leaf = [IO.Path]::GetFileName($full)
  $tmp = [IO.Path]::Combine($dir, ('.' + $leaf + '.tmp.' + [guid]::NewGuid().ToString('N')))
  $backup = [IO.Path]::Combine($dir, ('.' + $leaf + '.backup.' + [guid]::NewGuid().ToString('N')))
  try {
    [IO.File]::WriteAllText($tmp, $text, $enc)
    if (Test-Path -LiteralPath $full) { [IO.File]::Replace($tmp, $full, $backup) }
    else { [IO.File]::Move($tmp, $full) }
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  }
}

function Save-Json($path, $obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 20
  Save-TextFile $path ($json + "`n")
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

function Test-SkillPath($path) {
  $p = [string]$path
  if (-not $p) { return $true }
  if ($p.Contains('\') -or $p.StartsWith('/') -or $p -match '^[A-Za-z]:') { return $false }
  if ($p -match '(^|/)\.\.(/|$)') { return $false }
  if ($p -match '[\r\n]') { return $false }
  return $true
}

function Normalize-SkillPath($path) {
  # 与 .sh 版一致：去掉开头的 ./、结尾的 /、重复的 / 和内部的 /.
  # 绝对路径与 .. 原样返回，交给 Test-SkillPath 判非法。
  $p = [string]$path
  if (-not $p) { return '.' }
  if ($p.StartsWith('/') -or $p -match '^[A-Za-z]:') { return $p }
  while ($true) {
    if ($p.Contains('//')) { $p = $p -replace '//+', '/' }
    elseif ($p.StartsWith('./')) { $p = $p.Substring(2) }
    elseif ($p.Contains('/./')) { $p = $p -replace '/\./', '/' }
    elseif ($p.EndsWith('/')) { $p = $p.Substring(0, $p.Length - 1) }
    elseif ($p.EndsWith('/.')) { $p = $p.Substring(0, $p.Length - 2) }
    else { break }
  }
  if (-not $p) { $p = '.' }
  return $p
}

function Get-SkillName($skillMd) {
  # SKILL.md 必须是普通文件：历史安装里同名的目录会让 Get-Content 抛异常。
  if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) { return $null }
  try { $lines = @(Get-Content -LiteralPath $skillMd -TotalCount 40 -Encoding UTF8) }
  catch { return $null }
  if ($lines.Count -eq 0 -or $lines[0] -ne '---') { return $null }
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^---\s*$') { break }
    if ($lines[$i] -match '^name:\s*(.+)$') {
      return ($Matches[1].Trim().Trim('"').Trim("'"))
    }
  }
  return $null
}

function Get-InstalledVersion($name) {
  $skillDir = [IO.Path]::Combine($SkillsDir, $name)
  if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) { return $null }
  if (Test-Path -LiteralPath $StateFile) {
    try { $state = Read-Json $StateFile } catch { $state = $null }
    if ($state -and $state.skills) {
      $prop = $state.skills.PSObject.Properties[$name]
      if ($prop -and $prop.Value) {
        return @{
          kind = [string]$prop.Value.version_kind; version = [string]$prop.Value.version
          repo = [string]$prop.Value.repo; path = Normalize-SkillPath ([string]$prop.Value.path)
        }
      }
    }
  }
  $marker = [IO.Path]::Combine([IO.Path]::Combine($SkillsDir, $name), '.skill-manager.json')
  if (Test-Path -LiteralPath $marker) {
    try {
      $m = Read-Json $marker
      if ($m.adoption_pending -eq $true) { return $null }
      return @{
        kind = [string]$m.version_kind; version = [string]$m.version
        repo = [string]$m.repo; path = Normalize-SkillPath ([string]$m.path)
      }
    } catch { return $null }
  }
  return $null
}

function Save-StateEntry($name, $repo, $path, $ver, $kind, $now) {
  $dir = Get-ParentDir $StateFile
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

function Write-Marker($target, $repo, $path, $ver, $kind, $now, [bool]$pending = $false) {
  $m = [pscustomobject]@{
    repo = $repo; path = $path; version = $ver; version_kind = $kind; installed_at = $now
  }
  if ($pending) { $m | Add-Member -NotePropertyName adoption_pending -NotePropertyValue $true }
  Save-Json ([IO.Path]::Combine($target, '.skill-manager.json')) $m
}

function Adopt-Skill($name, $target, $repo, $path, $ver, $kind, $now) {
  $marker = [IO.Path]::Combine($target, '.skill-manager.json')
  $markerWritten = $false
  try {
    $existing = Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    if ($existing -and ($existing.PSIsContainer -or
        ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Read-Json $marker).adoption_pending -ne $true)) {
      throw "标记路径已被占用：$marker"
    }
    Write-Marker $target $repo $path $ver $kind $now $true
    $markerWritten = $true
    Save-StateEntry $name $repo $path $ver $kind $now
    return $true
  } catch {
    Write-ErrLine "$name：收编失败（$($_.Exception.Message)）"
    if ($markerWritten) {
      try { Remove-Item -LiteralPath $marker -Force }
      catch { Write-ErrLine "$name：无法撤销新建标记，请检查 $marker（$($_.Exception.Message)）" }
    }
    return $false
  }
}

function Invoke-NativeCapture([string]$file, [string[]]$nativeArgs, [bool]$mergeStderr = $false) {
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    if ($mergeStderr) { $out = @(& $file @nativeArgs 2>&1) }
    else { $out = @(& $file @nativeArgs 2>$null) }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  return @{ Code = $code; Output = $out }
}

function Invoke-GitCapture([string[]]$gitArgs) {
  $result = Invoke-NativeCapture 'git' $gitArgs
  if ($result.Code -ne 0) { return $null }
  return @($result.Output)
}

function Invoke-GitRun([string[]]$gitArgs) {
  $result = Invoke-NativeCapture 'git' $gitArgs $true
  return @{ Code = $result.Code; Output = ($result.Output | Out-String) }
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
  $m = [regex]::Match($tag, '^([A-Za-z][A-Za-z0-9._-]*-)?v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{
    Tag = $tag
    Major = [string]$m.Groups[2].Value
    Minor = [string]$m.Groups[3].Value
    Patch = [string]$m.Groups[4].Value
    Pre = $m.Groups[5].Value
  }
}

function Compare-NumericString([string]$a, [string]$b) {
  $aa = $a.TrimStart('0'); $bb = $b.TrimStart('0')
  if (-not $aa) { $aa = '0' }
  if (-not $bb) { $bb = '0' }
  if ($aa.Length -ne $bb.Length) { return $aa.Length - $bb.Length }
  return [string]::CompareOrdinal('x' + $aa, 'x' + $bb)
}

function Compare-SemVer($a, $b) {
  foreach ($part in @('Major', 'Minor', 'Patch')) {
    $c = Compare-NumericString ([string]$a.$part) ([string]$b.$part)
    if ($c -ne 0) { return [Math]::Sign($c) }
  }
  if (-not $a.Pre -and $b.Pre) { return 1 }
  if ($a.Pre -and -not $b.Pre) { return -1 }
  if (-not $a.Pre) { return 0 }
  $aa = @($a.Pre -split '\.'); $bb = @($b.Pre -split '\.')
  $count = [Math]::Min($aa.Count, $bb.Count)
  for ($i = 0; $i -lt $count; $i++) {
    $an = ($aa[$i] -match '^\d+$'); $bn = ($bb[$i] -match '^\d+$')
    if ($an -and $bn) { $c = Compare-NumericString $aa[$i] $bb[$i] }
    elseif ($an -ne $bn) { if ($an) { $c = -1 } else { $c = 1 } }
    else { $c = [string]::CompareOrdinal('x' + $aa[$i], 'x' + $bb[$i]) }
    if ($c -ne 0) { return $c }
  }
  return $aa.Count - $bb.Count
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
    $best = $parsed[0]
    foreach ($candidate in @($parsed | Select-Object -Skip 1)) {
      if ((Compare-SemVer $candidate $best) -gt 0) { $best = $candidate }
    }
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
    $cloneArgs = @('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--no-checkout', '--depth', '1')
    if ($sparse) { $cloneArgs += @('--filter=blob:none', '--sparse') }
    $cloneArgs += @("$GitHub/$repo.git", $dest)
    if (-not (Invoke-GitRetry $cloneArgs 3 $dest)) { return $false }
    if (-not (Invoke-GitRetry @('-C', $dest, 'fetch', '--quiet', '--depth', '1', 'origin', "refs/tags/$ver") 3)) { return $false }
    if ($sparse) {
      if (-not (Invoke-GitRetry @('-C', $dest, 'sparse-checkout', 'set', '--no-cone', "/$path/") 2)) { return $false }
    }
    if (-not (Invoke-GitRetry @('-c', 'advice.detachedHead=false', '-C', $dest, 'checkout', '--quiet', 'FETCH_HEAD') 2)) { return $false }
    $expected = Invoke-GitCapture @('-C', $dest, 'rev-parse', 'FETCH_HEAD^{commit}')
    $actual = Invoke-GitCapture @('-C', $dest, 'rev-parse', 'HEAD^{commit}')
    if (-not $expected -or -not $actual -or ([string]$expected[0]) -ne ([string]$actual[0])) { return $false }
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
      $sparseInit = Invoke-NativeCapture 'git' @('-C', $dest, 'sparse-checkout', 'init', '--no-cone')
      if ($sparseInit.Code -ne 0) { return $false }
      $sparseFile = [IO.Path]::Combine([IO.Path]::Combine([IO.Path]::Combine($dest, '.git'), 'info'), 'sparse-checkout')
      [IO.File]::WriteAllText($sparseFile, "/$path/`n", (New-Object System.Text.UTF8Encoding($false)))
      $fetchArgs += '--filter=blob:none'
    }
    $fetchArgs += @('origin', $ver)
    if (-not (Invoke-GitRetry $fetchArgs 3)) { return $false }
    if (-not (Invoke-GitRetry @('-c', 'advice.detachedHead=false', '-C', $dest, 'checkout', '--quiet', 'FETCH_HEAD') 2)) { return $false }
  }
  return $true
}

function Get-WebClientFile($url, $outFile, $accept) {
  $wc = New-Object System.Net.WebClient
  try {
    $wc.Headers.Add('User-Agent', 'fenix-selected-skills.ps1')
    if ($accept) { $wc.Headers.Add('Accept', $accept) }
    $wc.DownloadFile($url, $outFile)
    return $true
  } catch {
    return $false
  } finally {
    $wc.Dispose()
  }
}

function Get-RemoteSkillMd($repo, $ver, $path, $outFile) {
  $apiPath = 'SKILL.md'
  if ($path -and $path -ne '.') { $apiPath = "$path/SKILL.md" }
  $raw = "https://raw.githubusercontent.com/$repo/$ver/$apiPath"
  $api = "https://api.github.com/repos/$repo/contents/$apiPath?ref=$ver"
  if ($script:CurlCmd) {
    $curl = Invoke-NativeCapture $script:CurlCmd.Source @('-fsS', '--retry', '2', '--retry-delay', '1', '--connect-timeout', '5', '--max-time', '15', '-o', $outFile, $raw)
    if ($curl.Code -eq 0) { return $true }
  }
  if (Get-WebClientFile $raw $outFile $null) { return $true }
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    $result = Invoke-NativeCapture 'gh' @('api', "repos/$repo/contents/$apiPath?ref=$ver", '-H', 'Accept: application/vnd.github.raw')
    if ($result.Code -eq 0) {
      $lines = @($result.Output | ForEach-Object { [string]$_ })
      $enc = New-Object System.Text.UTF8Encoding($false)
      [IO.File]::WriteAllText($outFile, ($lines -join "`n") + "`n", $enc)
      if ((Get-Item -LiteralPath $outFile).Length -gt 0) { return $true }
    }
  }
  if (Get-WebClientFile $api $outFile 'application/vnd.github.raw') { return $true }
  return $false
}

function Install-One($name, [bool]$force = $false, [bool]$backup = $false) {
  if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') { Write-ErrLine "名称不合法：$name（只允许小写字母、数字、连字符）"; return $false }
  $data = Get-List
  $entry = Get-Entry $data $name
  if (-not $entry) { Write-ErrLine "名单中没有「$name」"; return $false }

  $path = Normalize-SkillPath ([string]$entry.path)
  if (-not (Test-SkillPath $path)) { Write-ErrLine "$name：path 不合法（$path）"; return $false }
  if (-not $entry.version) { Write-ErrLine "$name：版本为空，先运行 refresh $name"; return $false }
  if (-not $entry.repo -or $entry.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Write-ErrLine "$name：repo 不合法（$($entry.repo)）"; return $false }
  if (-not $path -or $path -eq '.') { Write-Warn "$name：技能位于仓库根目录，无法只取子目录，将下载整个仓库" }

  $target = [IO.Path]::Combine($SkillsDir, $name)
  $managed = ($null -ne (Get-InstalledVersion $name))
  if ((Test-Path -LiteralPath $target) -and -not $managed -and -not $force) {
    Write-Warn "$name：$target 已存在且不是本工具安装，跳过（--force 可覆盖）"
    return $true
  }
  $tmp = [IO.Path]::Combine($SkillsDir, ('.install-' + $name + '-' + [guid]::NewGuid().ToString('N')))
  $oldDest = [IO.Path]::Combine($tmp, 'old')
  $backupDir = $null
  $preserveOld = $false
  try {
    if (-not (Test-Path -LiteralPath $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Write-Info "$name：下载 $($entry.repo)@$(Format-Ver $entry.version_kind $entry.version)"
    $repoDir = [IO.Path]::Combine($tmp, 'repo')
    if (-not (Fetch-Repo $entry.repo $entry.version $entry.version_kind $repoDir $path)) {
      Write-ErrLine "$name：下载失败（$($entry.repo)@$(Format-Ver $entry.version_kind $entry.version)）"
      return $false
    }
    $src = $repoDir
    if ($path -and $path -ne '.') { $src = [IO.Path]::Combine($repoDir, $path.Replace('/', $DirSep)) }
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($src, 'SKILL.md')) -PathType Leaf)) {
      Write-ErrLine "$name：下载内容缺少 SKILL.md，请检查 path（当前：$path）"
      return $false
    }
    $staged = [IO.Path]::Combine($tmp, 'staged')
    New-Item -ItemType Directory -Path $staged -Force | Out-Null
    if ($path -and $path -ne '.') {
      Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $staged -Recurse -Force
      }
    } else {
      Get-ChildItem -LiteralPath $repoDir -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $staged -Recurse -Force
      }
    }
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
    Write-Marker $staged $entry.repo $path $entry.version $entry.version_kind $now

    if (Test-Path -LiteralPath $target) {
      if (-not $managed -and $backup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backupDir = [IO.Path]::Combine([IO.Path]::Combine($SkillsDir, '.backups'), "$name-$stamp-$PID")
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupDir) -Force | Out-Null
        $oldDest = $backupDir
      } elseif (-not $managed) {
        Write-Warn "$name：覆盖非本工具管理的目录 $target"
      }
      try {
        $preserveOld = $true
        Move-Item -LiteralPath $target -Destination $oldDest
      } catch {
        Write-ErrLine "$name：无法移走原目录，安装已取消（$($_.Exception.Message)）"
        return $false
      }
      if ($backupDir) { Write-Warn "$name：已备份原目录到 $backupDir" }
    }
    $newInstalled = $false
    try {
      Move-Item -LiteralPath $staged -Destination $target
      $newInstalled = $true
      Save-StateEntry $name $entry.repo $path $entry.version $entry.version_kind $now
    } catch {
      Write-ErrLine "$name：替换或状态写入失败（$($_.Exception.Message)）"
      if ($newInstalled) { Remove-Item -LiteralPath $target -Recurse -Force }
      if ($preserveOld) {
        if (Test-Path -LiteralPath $target) { throw "目标路径仍存在：$target" }
        Move-Item -LiteralPath $oldDest -Destination $target
        $preserveOld = $false
      }
      return $false
    }
    $preserveOld = $false
    Write-Ok "$name 已安装到 $target（$(Format-Ver $entry.version_kind $entry.version)）"
    return $true
  } catch {
    # 暂存标记、复制等任何异常都返回 false，让 sync/update 能回滚名单版本，
    # 而不是抛到顶层直接退出、留下「名单已升级但安装没成功」的状态。
    Write-ErrLine "$name：安装失败（$($_.Exception.Message)）"
    return $false
  } finally {
    if ($preserveOld -and (Test-Path -LiteralPath $oldDest)) {
      Write-ErrLine "$name：无法恢复原目录，备份保留在 $oldDest"
    } else {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
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

function Sync-One($data, $name, $latest, [bool]$force = $false, [bool]$dry = $false) {
  $entry = Get-Entry $data $name
  if (-not $entry) { Write-Warn "$name 不在名单中，跳过"; return $false }
  if (-not $latest) { Write-Warn "$name：查询 $($entry.repo) 失败，跳过"; return $false }
  $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
  $entryPath = Normalize-SkillPath ([string]$entry.path)

  $target = [IO.Path]::Combine($SkillsDir, $name)
  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    if ((Test-Path -LiteralPath $target) -and -not $force) {
      Write-Warn "$name：$target 不是目录且未纳入管理，跳过（--force 可备份并替换）"
      return $true
    }
    if ($dry) {
      if (Test-Path -LiteralPath $target) { Write-Info "[dry-run] $name：同名非目录将备份并替换为 $(Format-Ver $latest.kind $latest.version)" }
      else { Write-Info "[dry-run] $name：将安装 $(Format-Ver $latest.kind $latest.version)" }
      return $true
    }
    Write-Info "$name：目标缺失或不是目录，安装最新版"
    return [bool](Install-One $name $force $force)
  }

  $skillMd = [IO.Path]::Combine($target, 'SKILL.md')
  $missingMd = $false
  if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
    Write-Warn "$name：$target 缺少有效 SKILL.md，按待更新处理"
    $missingMd = $true
  }
  $sname = Get-SkillName $skillMd
  if ($sname -and $sname -ne $name) { Write-Warn "$name：目录名与 SKILL.md 的 name（$sname）不一致" }

  $inst = Get-InstalledVersion $name
  if ($inst) {
    $sourceChanged = ($inst.repo -ne [string]$entry.repo -or $inst.path -ne $entryPath)
    if ($inst.version -eq $latest.version -and $inst.kind -eq $latest.kind -and -not $missingMd -and -not $sourceChanged) {
      Write-Ok "$name 已是最新（$(Format-Ver $latest.kind $latest.version)）"
      return $true
    }
    if ($dry) {
      if ($sourceChanged) { Write-Info "[dry-run] $name：技能来源变化（$($inst.repo)/$($inst.path) → $($entry.repo)/$entryPath），将重新安装" }
      else { Write-Info "[dry-run] $name：$(Format-Ver $inst.kind $inst.version) → $(Format-Ver $latest.kind $latest.version)" }
      return $true
    }
    if ($sourceChanged) { Write-Info "$name：技能来源变化（$($inst.repo)/$($inst.path) → $($entry.repo)/$entryPath），重新安装" }
    else { Write-Info "$name：$(Format-Ver $inst.kind $inst.version) → $(Format-Ver $latest.kind $latest.version)" }
    return [bool](Install-One $name $true $false)
  }

  $tmpMd = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('skill-md-' + [guid]::NewGuid().ToString('N') + '.md'))
  try {
    if (Get-RemoteSkillMd ([string]$entry.repo) $latest.version $entryPath $tmpMd) {
      $same = $false
      try {
        $same = ((Get-FileHash -LiteralPath $tmpMd -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $skillMd -Algorithm SHA256).Hash)
      } catch { $same = $false }
      if ($same) {
        if ($dry) {
          Write-Info "[dry-run] $name：内容与最新版一致，将纳入管理"
        } elseif (Adopt-Skill $name $target ([string]$entry.repo) $entryPath $latest.version $latest.kind $now) {
          Write-Ok "$name 已存在且内容与最新版一致，纳入管理"
        } else {
          return $false
        }
      } elseif (-not $force) {
        Write-Warn "$name：已存在但内容与最新版不同，跳过（--force 可备份并更新）"
      } elseif ($dry) {
        Write-Info "[dry-run] $name：已存在但内容不同，将备份并更新"
      } else {
        Write-Info "$name：已存在但内容与最新版不同，备份后更新"
        return [bool](Install-One $name $true $true)
      }
    } elseif ($force) {
      if ($dry) { Write-Info "[dry-run] $name：无法校验远端内容，将备份并更新" }
      else {
        Write-Warn "$name：无法校验远端内容，按 --force 备份后更新"
        return [bool](Install-One $name $true $true)
      }
    } else {
      Write-Warn "$name：已存在但无法获取远端 SKILL.md 校验，跳过（--force 可备份并更新）"
    }
  } finally {
    Remove-Item -LiteralPath $tmpMd -Force -ErrorAction SilentlyContinue
  }
  return $true
}

function Get-ManagedNames {
  if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
  try { $state = Read-Json $StateFile } catch { return @() }
  if (-not $state.skills) { return @() }
  return @($state.skills.PSObject.Properties.Name)
}

function ConvertTo-MdCell($value) {
  $text = [string]$value
  $text = [regex]::Replace($text, "\r\n|\r|\n", ' ')
  return $text.Replace('|', '\|')
}

function Render-TableLines {
  $data = Get-List
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('| 类型 | 名称 | GitHub | 仓库路径 | 名单版本 | 说明 |')
  $lines.Add('| --- | --- | --- | --- | --- | --- |')
  $rows = $data.skills | Sort-Object @{ Expression = {
      $idx = $TypeOrder.IndexOf([string]$_.type)
      if ($idx -lt 0) { 99 } else { $idx }
    } }, @{ Expression = { [string]$_.name } }
  foreach ($s in $rows) {
    $p = Normalize-SkillPath ([string]$s.path)
    if ($p -eq '.') { $p = '—' }
    $lines.Add("| $(ConvertTo-MdCell $s.type) | $(ConvertTo-MdCell $s.name) | [$($s.repo)]($GitHub/$($s.repo)) | $(ConvertTo-MdCell $p) | $(Format-Ver $s.version_kind $s.version) | $(ConvertTo-MdCell $s.description) |")
  }
  return $lines
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
  foreach ($line in (Render-TableLines)) { $lines.Add($line) }
  $lines.Add('')
  $lines.Add('同步：`fenix-selected-skills.sh sync`（Windows：`fenix-selected-skills.cmd sync`） · 查状态：`fenix-selected-skills.sh status` · 帮助：`fenix-selected-skills.sh help`')
  return $lines
}

function Cmd-List {
  foreach ($line in (Render-TableLines)) { Write-Output $line }
}

function Cmd-Render {
  $lines = Render-Lines
  Save-TextFile $MdFile (($lines -join "`n") + "`n")
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
  $failed = $false
  foreach ($name in $names) { if (-not (Install-One $name $force $false)) { $failed = $true } }
  if ($failed) { Fail '部分技能安装失败' }
}

function Cmd-Sync([string[]]$names, [bool]$force = $false, [bool]$dry = $false) {
  $data = Get-List
  if (-not $names -or $names.Count -eq 0) { $names = @($data.skills | ForEach-Object { $_.name }) }
  # 重复传入同名技能只处理一次：否则第二遍会把已升级的版本当成回滚快照。
  $names = @($names | Select-Object -Unique)
  Write-Info "目标目录：$SkillsDir"
  $cache = @{}
  $latestByName = @{}
  $originalByName = @{}
  $failed = $false
  foreach ($name in $names) {
    $entry = Get-Entry $data $name
    if (-not $entry) { Write-Warn "$name 不在名单中，跳过"; $failed = $true; continue }
    $repo = [string]$entry.repo
    if (-not $cache.ContainsKey($repo)) { $cache[$repo] = Resolve-Version $repo }
    $latest = $cache[$repo]
    if (-not $latest) { Write-Warn "$name：查询 $repo 失败，跳过"; $failed = $true; continue }
    $latestByName[$name] = $latest
    if (-not $originalByName.ContainsKey($name)) {
      $originalByName[$name] = [pscustomobject]@{
        version = [string]$entry.version; kind = [string]$entry.version_kind; checkedAt = [string]$entry.checked_at
      }
    }
    if (-not $dry) { Update-EntryVersion $data $name $latest.version $latest.kind (Get-Date -Format 'yyyy-MM-dd HH:mm') }
  }
  if (-not $dry) {
    $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
    Save-Json $DataFile $data
  }
  foreach ($name in $names) {
    if ($latestByName.ContainsKey($name)) {
      try {
        $success = Sync-One $data $name $latestByName[$name] $force $dry
      } catch {
        Write-ErrLine "$name：同步失败（$($_.Exception.Message)）"
        $success = $false
      }
      if (-not $success) {
        $failed = $true
        if (-not $dry) {
          $original = $originalByName[$name]
          Update-EntryVersion $data $name $original.version $original.kind $original.checkedAt
        }
      }
    }
  }
  if (-not $dry -and $failed) { Save-Json $DataFile $data }
  if ($dry) { Write-Info "dry-run 结束，未改动文件" }
  else { Cmd-Render }
  if ($failed) { Fail '部分技能同步失败' }
}

function Cmd-Update([string[]]$names) {
  $data = Get-List
  if (-not $names -or $names.Count -eq 0) { $names = Get-ManagedNames }
  if (-not $names -or $names.Count -eq 0) { Fail "还没有安装记录，先运行 fenix-selected-skills.ps1 sync 或 install" }
  $cache = @{}
  $failed = $false
  foreach ($name in $names) {
    $entry = Get-Entry $data $name
    if (-not $entry) { Write-Warn "$name 不在名单中，跳过"; $failed = $true; continue }
    $original = [pscustomobject]@{
      version = [string]$entry.version; kind = [string]$entry.version_kind; checkedAt = [string]$entry.checked_at
    }
    $repo = [string]$entry.repo
    $entryPath = Normalize-SkillPath ([string]$entry.path)
    if (-not $cache.ContainsKey($repo)) { $cache[$repo] = Resolve-Version $repo }
    $latest = $cache[$repo]
    if (-not $latest) { Write-Warn "$name：查询 $repo 失败，跳过"; $failed = $true; continue }
    $target = [IO.Path]::Combine($SkillsDir, $name)
    if (-not (Test-Path -LiteralPath $target -PathType Container) -and (@(Get-ManagedNames) -contains $name)) {
      Update-EntryVersion $data $name $latest.version $latest.kind (Get-Date -Format 'yyyy-MM-dd HH:mm')
      Save-Json $DataFile $data
      Write-Info "$name：技能目录缺失，按最新版重新安装"
      if (-not (Install-One $name $true $false)) {
        $failed = $true
        Update-EntryVersion $data $name $original.version $original.kind $original.checkedAt
        Save-Json $DataFile $data
      }
      continue
    }
    $inst = Get-InstalledVersion $name
    if (-not $inst) { Write-Warn "$name 尚未安装或没有版本记录，跳过（用 sync）"; continue }
    $sourceChanged = ($inst.repo -ne $repo -or $inst.path -ne $entryPath)
    Update-EntryVersion $data $name $latest.version $latest.kind (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Save-Json $DataFile $data
    if ($inst.version -eq $latest.version -and $inst.kind -eq $latest.kind -and -not $sourceChanged) {
      Write-Ok "$name 已是最新（$(Format-Ver $latest.kind $latest.version)）"
    } else {
      if ($sourceChanged) { Write-Info "$name：技能来源变化（$($inst.repo)/$($inst.path) → $repo/$entryPath），重新安装" }
      else { Write-Info "$name：$(Format-Ver $inst.kind $inst.version) → $(Format-Ver $latest.kind $latest.version)" }
      if (-not (Install-One $name $true $false)) {
        $failed = $true
        Update-EntryVersion $data $name $original.version $original.kind $original.checkedAt
        Save-Json $DataFile $data
      }
    }
  }
  $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
  Save-Json $DataFile $data
  Cmd-Render
  if ($failed) { Fail '部分技能更新失败' }
}

function Cmd-Status {
  $data = Get-List
  Write-Info "目标目录：$SkillsDir"
  Write-Output ("{0,-30} {1,-12} {2,-12} {3}" -f '名称', '已安装', '名单版本', '状态')
  foreach ($s in $data.skills) {
    $inst = Get-InstalledVersion ([string]$s.name)
    $instText = '-'
    if ($inst) { $instText = Format-Ver $inst.kind $inst.version }
    $latestText = Format-Ver $s.version_kind $s.version
    if ($instText -eq '-') {
      $target = [IO.Path]::Combine($SkillsDir, [string]$s.name)
      if (Test-Path -LiteralPath $target) { $st = '未托管' } else { $st = '未安装' }
    }
    elseif ($inst.kind -eq [string]$s.version_kind -and $inst.version -eq [string]$s.version) { $st = '已最新' }
    else { $st = '可更新' }
    Write-Output ("{0,-30} {1,-12} {2,-12} {3}" -f $s.name, $instText, $latestText, $st)
  }
}

function Get-CurlCode($url, $accept) {
  $curlArgs = @('-sS', '-o', $script:NullDevice, '-w', '%{http_code}', '--connect-timeout', '4', '--max-time', '10', '--retry', '1', '--retry-delay', '1')
  if ($accept) { $curlArgs += @('-H', "Accept: $accept") }
  $curlArgs += $url
  $result = Invoke-NativeCapture $script:CurlCmd.Source $curlArgs
  $text = ($result.Output | Out-String).Trim()
  if ($text -match '(\d{3})$') { return $Matches[1] }
  return '000'
}

function Get-WebClientCode($url, $accept) {
  $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), [guid]::NewGuid().ToString('N'))
  $wc = New-Object System.Net.WebClient
  try {
    $wc.Headers.Add('User-Agent', 'fenix-selected-skills.ps1')
    if ($accept) { $wc.Headers.Add('Accept', $accept) }
    $wc.DownloadFile($url, $tmp)
    return '200'
  } catch {
    $response = $_.Exception.Response
    if (-not $response -and $_.Exception.InnerException) { $response = $_.Exception.InnerException.Response }
    if ($response) { return ([string][int]$response.StatusCode) }
    return '000'
  } finally {
    $wc.Dispose()
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Get-RemoteCode($repo, $ver, $path) {
  $apiPath = 'SKILL.md'
  if ($path -and $path -ne '.') { $apiPath = "$path/SKILL.md" }
  $raw = "https://raw.githubusercontent.com/$repo/$ver/$apiPath"
  $api = "https://api.github.com/repos/$repo/contents/$apiPath?ref=$ver"
  if ($script:CurlCmd) { $rawCode = Get-CurlCode $raw }
  else { $rawCode = Get-WebClientCode $raw $null }
  if ($rawCode -eq '200') { return '200' }
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    $result = Invoke-NativeCapture 'gh' @('api', "repos/$repo/contents/$apiPath?ref=$ver")
    if ($result.Code -eq 0) { return '200' }
  }
  if ($script:CurlCmd) { $apiCode = Get-CurlCode $api 'application/vnd.github+json' }
  else { $apiCode = Get-WebClientCode $api 'application/vnd.github+json' }
  if ($apiCode -ne '000') { return $apiCode }
  return $rawCode
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
    $path = Normalize-SkillPath ([string]$s.path)
    if (-not (Test-SkillPath $path)) { Write-ErrLine "$name：path 必须是相对路径、使用正斜杠且不能包含 ..（$path）"; $errors++ }
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
  $path = Normalize-SkillPath $path
  if (-not $name -or -not $type -or -not $repo) { Fail "add 需要 --name、--type、--repo" }
  if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail "名称不合法：$name" }
  if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { Fail "repo 不合法：$repo（需 owner/name）" }
  if (-not (Test-SkillPath $path)) { Fail "path 不合法：$path（需相对路径、正斜杠且不能包含 ..）" }
  $data = Get-List
  if (Get-Entry $data $name) { Fail "名单中已有「$name」" }
  $entry = [pscustomobject]@{
    type = $type; name = $name; repo = $repo; path = $path
    version = ''; version_kind = 'commit'; description = $desc; checked_at = ''
  }
  $data.skills = @($data.skills) + $entry
  Save-Json $DataFile $data
  Write-Ok "已添加 $name"
  if ($opts['noRefresh']) {
    $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
    Save-Json $DataFile $data
    Cmd-Render
  } else { Cmd-Refresh @($name) }
}

function Cmd-Remove($name) {
  $data = Get-List
  if (-not (Get-Entry $data $name)) { Fail "名单中没有「$name」" }
  $data.skills = @($data.skills | Where-Object { $_.name -ne $name })
  $data.updated_at = Get-Date -Format 'yyyy-MM-dd'
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
  .\fenix-selected-skills.ps1 status [--target ...]    安装状态与名单记录版本（不联网）
  .\fenix-selected-skills.ps1 list                     打印名单表格
  .\fenix-selected-skills.ps1 render                   重新生成 fenix-selected-skills.md
  .\fenix-selected-skills.ps1 refresh [名称...]         查询并写回最新版本（默认全部）
  .\fenix-selected-skills.ps1 check [--network]        校验名单；--network 验证远端 SKILL.md
  .\fenix-selected-skills.ps1 add --name N --type T --repo O/R [--path P] [--desc D] [--no-refresh]
  .\fenix-selected-skills.ps1 remove <名称>
  .\fenix-selected-skills.ps1 env                      打印环境信息
  .\fenix-selected-skills.ps1 help                     显示本帮助

目标目录：
  --target user（默认 ~\.claude\skills，CLAUDE_SKILLS_DIR 可覆盖）
  --target project（当前目录\.claude\skills）
  --target <目录>
  状态文件：<目标目录>\.skills-manager.json（SKILLS_STATE_FILE 可覆盖）
  path 会自动归一化：去掉开头的 ./、结尾的 /、重复的 / 和内部的 /.

示例：
  .\fenix-selected-skills.ps1 sync
  .\fenix-selected-skills.ps1 sync docx pdf --dry-run
  .\fenix-selected-skills.ps1 sync --target project
  .\fenix-selected-skills.ps1 check --network

说明：
  安装先下载并校验到临时目录，成功后才替换旧目录，失败保留原版本。
  安装只拉取 skills[].path 对应的子目录（blobless + sparse checkout），不下载整个仓库。
  sync/update 会联网并把版本写回名单 JSON 和生成的 Markdown；sync --dry-run 不写任何文件。
  sync/install/update 任一安装失败时最终返回非零；sync/update 恢复失败条目的原 JSON 版本记录。
  版本不变但 repo/path 变化时也会重新安装。
  非托管同名目录内容不同或无法校验时，必须加 --force 才备份到 <目标目录>\.backups\ 后替换。
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

function Assert-CommonArgs($parsed, [string[]]$allowed, [bool]$allowNames = $true) {
  $flags = @{ force = '--force'; dry = '--dry-run'; network = '--network'; target = '--target'; noRefresh = '--no-refresh' }
  foreach ($key in $flags.Keys) {
    if ($parsed.opts[$key] -and $allowed -notcontains $key) { Fail "当前命令不支持 $($flags[$key])" }
  }
  if (-not $allowNames -and $parsed.names.Count -gt 0) { Fail "当前命令不接受名称或位置参数：$($parsed.names -join ' ')" }
}

function Parse-NamedArgs([string[]]$inputArgs) {
  $opts = @{ name = $null; type = $null; repo = $null; path = $null; desc = $null; noRefresh = $false }
  $i = 0
  while ($i -lt $inputArgs.Count) {
    $a = [string]$inputArgs[$i]
    switch -Regex ($a) {
      '^--name$' { if ($i + 1 -ge $inputArgs.Count) { Fail '--name 需要参数' }; $opts.name = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--type$' { if ($i + 1 -ge $inputArgs.Count) { Fail '--type 需要参数' }; $opts.type = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--repo$' { if ($i + 1 -ge $inputArgs.Count) { Fail '--repo 需要参数' }; $opts.repo = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--path$' { if ($i + 1 -ge $inputArgs.Count) { Fail '--path 需要参数' }; $opts.path = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--desc$' { if ($i + 1 -ge $inputArgs.Count) { Fail '--desc 需要参数' }; $opts.desc = [string]$inputArgs[$i + 1]; $i += 2; break }
      '^--no-refresh$' { $opts.noRefresh = $true; $i++; break }
      default { Fail "未知参数：$a"; break }
    }
  }
  return $opts
}

# ---------------- 入口 ----------------

try {
  switch ($Command.ToLowerInvariant()) {
    'help' { if ($Rest.Count -gt 0) { Fail 'help 不接受参数' }; Cmd-Help }
    { $_ -in @('-h', '--help') } { if ($Rest.Count -gt 0) { Fail 'help 不接受参数' }; Cmd-Help }
    'env' { if ($Rest.Count -gt 0) { Fail 'env 不接受参数' }; Cmd-Env }
    'list' { Ensure-Data; if ($Rest.Count -gt 0) { Fail 'list 不接受参数' }; Cmd-List }
    'render' { Ensure-Data; if ($Rest.Count -gt 0) { Fail 'render 不接受参数' }; Cmd-Render }
    'refresh' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      Assert-CommonArgs $p @()
      Cmd-Refresh $p.names
    }
    'sync' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      Assert-CommonArgs $p @('force', 'dry', 'target')
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Sync $p.names $p.opts.force $p.opts.dry
    }
    'install' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      Assert-CommonArgs $p @('force', 'target')
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Install $p.names $p.opts.force
    }
    'update' {
      Ensure-Git; Ensure-Data
      $p = Split-CommonArgs $Rest
      Assert-CommonArgs $p @('target')
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Update $p.names
    }
    'status' {
      Ensure-Data
      $p = Split-CommonArgs $Rest
      Assert-CommonArgs $p @('target') $false
      if ($p.opts.target) { Apply-Target $p.opts.target }
      Cmd-Status
    }
    'check' {
      Ensure-Data
      $p = Split-CommonArgs $Rest
      Assert-CommonArgs $p @('network') $false
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
