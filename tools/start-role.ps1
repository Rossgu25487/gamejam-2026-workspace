[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('planner','lead','gameplay','integration','ui_art','visual_art','qa','ops')]
  [string]$Role,
  [string]$BaseBranch = 'main'
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot

function Invoke-GitValue([string[]]$Arguments) {
  $output = @(& git -C $sourceRoot @Arguments 2>&1 | ForEach-Object {$_.ToString()})
  if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
  return ($output -join "`n").Trim()
}

$commonDirectory = Invoke-GitValue @('rev-parse','--path-format=absolute','--git-common-dir')
$primaryRoot = Split-Path -Parent $commonDirectory
if (-not (Test-Path -LiteralPath (Join-Path $primaryRoot 'workspace/manifest.json'))) {
  throw '未定位到本工作区主目录，请从克隆后的仓库执行本脚本。'
}
$baseCommit = Invoke-GitValue @('rev-parse','--verify',($BaseBranch+'^{commit}'))
$branch = 'codex/'+$Role+'/workspace'
$roleDirectory = [IO.Path]::GetFullPath((Join-Path $primaryRoot ('.local/roles/'+$Role)))
$expectedParent = [IO.Path]::GetFullPath((Join-Path $primaryRoot '.local/roles'))
if ((Split-Path -Parent $roleDirectory) -ne $expectedParent) { throw '岗位目录不在预期范围内。' }

if (Test-Path -LiteralPath (Join-Path $roleDirectory '.git')) {
  $actualBranch = (& git -C $roleDirectory branch --show-current | Out-String).Trim()
  $actualCommon = (& git -C $roleDirectory rev-parse --path-format=absolute --git-common-dir | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $actualBranch -ne $branch -or $actualCommon -ne $commonDirectory) {
    throw '目录已关联其他仓库或分支，未做覆盖。请先核对现有工作。'
  }
  $state = 'existing'
} else {
  if ((Test-Path -LiteralPath $roleDirectory) -and @(Get-ChildItem -LiteralPath $roleDirectory -Force).Count -gt 0) {
    throw '目标目录已有内容，未做覆盖。'
  }
  New-Item -ItemType Directory -Path $expectedParent -Force | Out-Null
  & git -C $sourceRoot show-ref --verify --quiet ('refs/heads/'+$branch)
  $branchExists = $LASTEXITCODE -eq 0
  if ($branchExists) {
    $null = Invoke-GitValue @('worktree','add',$roleDirectory,$branch)
  } else {
    $null = Invoke-GitValue @('worktree','add','-b',$branch,$roleDirectory,$baseCommit)
  }
  $state = 'created'
}
$head = (& git -C $roleDirectory rev-parse --short HEAD | Out-String).Trim()
$dirty = @(& git -C $roleDirectory status --porcelain).Count -gt 0
[pscustomobject]@{
  Role=$Role
  Path=$roleDirectory
  Branch=$branch
  Commit=$head
  State=$state
  HasLocalChanges=$dirty
  Note='在此独立目录打开 Codex 和 game/project.godot；已有工作不会自动重置或同步。'
} | ConvertTo-Json
