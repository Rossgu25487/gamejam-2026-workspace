[CmdletBinding()]
param(
  [ValidateSet('editor','run','check','test','export')][string]$Action = 'editor',
  [string]$Godot = $env:GODOT_BIN,
  [string]$Preset = 'Windows Desktop'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'game'
if (-not $Godot) {
  foreach ($name in @('godot','godot4')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { $Godot = $command.Source; break }
  }
}
if (-not $Godot -or -not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
  throw '请通过 -Godot 指定本机 Godot 4.7.2 路径，或设置 GODOT_BIN。无需修改全局 PATH。'
}
$engineVersion = (& $Godot --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $engineVersion -notmatch '^4\.7\.2\.stable\.') {
  throw "本工程固定 Godot 4.7.2 stable；实际返回：$engineVersion。版本调整应先同步团队。"
}
$localRoot = Join-Path $repoRoot '.local'
New-Item -ItemType Directory -Path $localRoot -Force | Out-Null

function Invoke-EngineCheck([string[]]$EngineArguments, [string]$LogName) {
  $logFile = Join-Path $localRoot $LogName
  $lines = @(& $Godot @EngineArguments 2>&1 | ForEach-Object { $_.ToString() })
  $code = $LASTEXITCODE
  $lines | Set-Content -LiteralPath $logFile -Encoding utf8
  $lines | Write-Output
  if ($code -ne 0 -or ($lines -match 'SCRIPT ERROR:|Parse Error:|^ERROR:')) {
    throw "Godot 检查失败，日志：$logFile"
  }
}

switch ($Action) {
  'editor' { & $Godot --path $projectRoot --editor }
  'run' { & $Godot --path $projectRoot }
  'check' { Invoke-EngineCheck @('--headless','--path',$projectRoot,'--editor','--import','--quit') 'import.log' }
  'test' {
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--editor','--import','--quit') 'import.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/test_suite.gd') 'tests.log'
  }
  'export' {
    if ($Preset -ne 'Windows Desktop') { throw '当前仅配置 Windows Desktop；新增目标先补齐并验证对应导出预设。' }
    $outputDir = Join-Path $repoRoot 'builds/windows'
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--editor','--import','--quit') 'import.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--export-debug',$Preset,(Join-Path $outputDir 'collaboration-demo.exe')) 'export.log'
    Write-Output "已导出 $outputDir；仍需独立运行成品核对画面与输入。"
  }
}
