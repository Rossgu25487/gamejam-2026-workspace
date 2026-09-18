[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot '岗位工作流'
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'workspace/manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$files = @((Join-Path $sourceRoot '00_分发与使用说明.md'))
$files += @($manifest.roles | ForEach-Object {Join-Path $repoRoot $_.workflow})
if ($manifest.roles.Count -ne 8 -or @($files | Select-Object -Unique).Count -ne 9) {
  throw '分发包需要一份说明和八份独立岗位文件。'
}
$roleFiles = @{}
foreach ($role in $manifest.roles) { $roleFiles[[IO.Path]::GetFullPath((Join-Path $repoRoot $role.workflow))] = $role }
foreach ($file in $files) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "缺少源文件：$file" }
  $text = [IO.File]::ReadAllText($file)
  if ($text -notmatch 'v2\.0' -or $text -notmatch 'https://github\.com/Rossgu25487/gamejam-2026-workspace') {
    throw "版本或仓库入口缺失：$file"
  }
  if ($roleFiles.ContainsKey([IO.Path]::GetFullPath($file))) {
    $role = $roleFiles[[IO.Path]::GetFullPath($file)]
    foreach ($required in @($role.id, $role.handoff, '12 小时', '10 月 19 日 00:00')) {
      if (-not $text.Contains($required)) { throw "岗位文件缺少必要上下文 '$required'：$file" }
    }
    foreach ($link in [regex]::Matches($text, '\]\(([^)]+)\)')) {
      if ($link.Groups[1].Value -notmatch '^(https?://|#)') { throw "岗位附件存在依赖其他文件的相对链接：$file" }
    }
  }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$outputDirectory = Join-Path $repoRoot '分发包'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$output = Join-Path $outputDirectory '八人岗位工作流_v2.zip'
$temporary = $output + '.tmp'
$stream = [IO.File]::Open($temporary,[IO.FileMode]::Create)
$archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false,[Text.Encoding]::UTF8)
try {
  foreach ($file in $files | Sort-Object) {
    $entry = $archive.CreateEntry([IO.Path]::GetFileName($file),[IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [DateTimeOffset](Get-Item -LiteralPath $file).LastWriteTimeUtc
    $destination = $entry.Open()
    $source = [IO.File]::OpenRead($file)
    try { $source.CopyTo($destination) } finally { $source.Dispose(); $destination.Dispose() }
  }
} finally { $archive.Dispose() }

$check = [IO.Compression.ZipFile]::OpenRead($temporary)
try {
  if ($check.Entries.Count -ne 9) { throw 'ZIP 文件数不正确。' }
  foreach ($entry in $check.Entries) {
    $sourcePath = Join-Path $sourceRoot $entry.FullName
    $expected = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $entryStream = $entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($entryStream)).Replace('-','') }
    finally { $entryStream.Dispose(); $sha.Dispose() }
    if ($actual -ne $expected) { throw "ZIP 内容与源文件不一致：$($entry.FullName)" }
  }
} finally { $check.Dispose() }

$resolvedDirectory = [IO.Path]::GetFullPath($outputDirectory)
if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($output)) -ne $resolvedDirectory -or
    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($temporary)) -ne $resolvedDirectory) {
  throw '分发文件不在预期输出目录中。'
}
Move-Item -LiteralPath $temporary -Destination $output -Force
[pscustomobject]@{Archive=$output;Files=9;SHA256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash} | ConvertTo-Json
