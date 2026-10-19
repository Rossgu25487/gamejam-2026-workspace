[CmdletBinding()]
param(
  [ValidateSet('editor','run','example','system-test','check','test','export')][string]$Action = 'editor',
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
  'example' { & $Godot --path $projectRoot 'res://examples/rainy_library.tscn' }
  'system-test' { & $Godot --path $projectRoot 'res://examples/system_test_demo.tscn' }
  'check' { Invoke-EngineCheck @('--headless','--path',$projectRoot,'--editor','--import','--quit') 'import.log' }
  'test' {
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--editor','--import','--quit') 'import.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/test_suite.gd') 'tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/story_config_test.gd') 'story-config-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/story_example_test.gd','--quit-after','3600') 'story-example-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/core_gameplay_test.gd') 'core-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/core_audit_test.gd') 'core-audit-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/core_input_test.gd') 'core-input-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/navigation_checks.gd') 'navigation-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/confirmation_repeat_test.gd') 'confirmation-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/scene_interaction_test.gd') 'scene-interaction-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/objective_navigation_test.gd') 'objective-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/objective_navigation_page_test.gd') 'objective-page-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/audio_service_test.gd') 'audio-service-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/audio_integration_test.gd') 'audio-integration-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/narrative_test.gd') 'narrative-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/map_workbook_loader_test.gd') 'map-workbook-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/map_navigation_test.gd') 'map-navigation-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/map_input_test.gd','--quit-after','1200') 'map-input-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/cat_service_test.gd') 'cat-service-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/handbook_talk_records_test.gd') 'handbook-talk-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/system_audit_test.gd','--quit-after','2400') 'system-audit-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/system_test_package_test.gd','--quit-after','2400') 'system-test-package.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/system_test_demo_input_test.gd','--quit-after','2400') 'system-test-input.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/aurora_configuration_test.gd') 'aurora-configuration-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/aurora_core_test.gd') 'aurora-core-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/aurora_session_test.gd') 'aurora-session-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/aurora_playthrough_test.gd','--quit-after','2400') 'aurora-playthrough-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/aurora_page_test.gd','--quit-after','2400') 'aurora-page-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/aurora_investigation_bug_test.gd','--quit-after','2400') 'aurora-investigation-bug-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/final_t00_input_test.gd') 't00-opening-input-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/final_t00_input_test.gd','--','--recovery') 't00-old-save-recovery-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/debug_console_test.gd') 'debug-console-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/debug_console_ui_test.gd') 'debug-console-ui-tests.log'
    Invoke-EngineCheck @('--headless','--path',$projectRoot,'--script','res://tests/debug_autoplay_test.gd') 'debug-autoplay-tests.log'
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
