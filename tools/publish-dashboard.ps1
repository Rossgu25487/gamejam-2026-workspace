[CmdletBinding()]
param(
  [string]$AuthorName,
  [string]$AuthorEmail
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Git([string[]]$Arguments) {
  $output = @(& git -C $repoRoot @Arguments 2>&1 | ForEach-Object { $_.ToString() })
  if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
  return ($output -join "`n").Trim()
}

$remote = Invoke-Git @('remote','get-url','origin')
if ($remote -notmatch 'github\.com[:/]Rossgu25487/gamejam-2026-workspace(?:\.git)?$') {
  throw '当前 origin 与团队仓库不符，未发布。'
}
if (-not $AuthorName) { $AuthorName = (& git -C $repoRoot config user.name | Out-String).Trim() }
if (-not $AuthorEmail) { $AuthorEmail = (& git -C $repoRoot config user.email | Out-String).Trim() }
if (-not $AuthorName -or -not $AuthorEmail) {
  throw '请配置本人的 Git 提交身份，或提供 -AuthorName 与 -AuthorEmail。'
}
$uncommitted = Invoke-Git @('status','--porcelain','--','site','tools/build-dashboard.mjs','tools/dashboard-data.mjs','workspace/roadmap.json','workspace/manifest.json')
if ($uncommitted) { throw '请先提交本次网页、数据构建或排期修改，再发布对应版本。游戏中的其他未完成工作会保留。' }
$workspaceCommit = Invoke-Git @('rev-parse','HEAD')
$remoteMain = (Invoke-Git @('ls-remote','--heads','origin','main') -split '\s+')[0]
if ($workspaceCommit -ne $remoteMain) { throw '当前提交与远端 main 不同，请先同步或推送已确认版本，再发布网页。' }
& node (Join-Path $PSScriptRoot 'build-dashboard.mjs')
if ($LASTEXITCODE -ne 0) { throw '网页数据构建失败，未发布。' }
$snapshot = Get-Content -LiteralPath (Join-Path $repoRoot 'site/data/snapshot.json') -Encoding UTF8 -Raw | ConvertFrom-Json
if ($snapshot.version.sha -ne $workspaceCommit) { throw '构建期间 main 已更新，请取得新版本后再发布；现有线上页面未更改。' }

$files = @('index.html','styles.css','app.js','data/snapshot.json','data/github-data.mjs','.nojekyll')
$remoteBranch = Invoke-Git @('ls-remote','--heads','origin','gh-pages')
$parent = ''
if ($remoteBranch) {
  $null = Invoke-Git @('fetch','origin','refs/heads/gh-pages:refs/remotes/origin/gh-pages')
  $parent = Invoke-Git @('rev-parse','refs/remotes/origin/gh-pages')
}
$localDirectory = Join-Path $repoRoot '.local'
New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
$previousIndex = $env:GIT_INDEX_FILE
try {
  $env:GIT_INDEX_FILE = Join-Path $localDirectory 'dashboard-publish.index'
  $null = Invoke-Git @('read-tree','--empty')
  foreach ($file in $files) {
    $path = Join-Path (Join-Path $repoRoot 'site') $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少发布文件：$file" }
    $blob = Invoke-Git @('hash-object','-w','--no-filters','--',$path)
    $null = Invoke-Git @('update-index','--add','--cacheinfo',("100644,"+$blob+","+$file))
  }
  $tree = Invoke-Git @('write-tree')
} finally {
  [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE',$previousIndex,'Process')
}
$arguments = @('-c',('user.name='+$AuthorName),'-c',('user.email='+$AuthorEmail),'commit-tree',$tree)
if ($parent) { $arguments += @('-p',$parent) }
$arguments += @('-m','Publish team workspace')
$commit = Invoke-Git $arguments
$result = Invoke-Git @('push','origin',($commit+':refs/heads/gh-pages'))
Write-Output $result
[pscustomobject]@{Branch='gh-pages';Commit=$commit;URL='https://rossgu25487.github.io/gamejam-2026-workspace/'} | ConvertTo-Json
