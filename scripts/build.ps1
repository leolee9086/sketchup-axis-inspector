# SPDX-License-Identifier: AGPL-3.0-only
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = '1.1.0'
$output = Join-Path $root "release/zhi-axis-inspector-$version.rbz"
if ((Test-Path $output) -and -not $Force) { throw "包已存在，确认重建后添加 -Force：$output" }
New-Item -ItemType Directory -Force (Split-Path $output -Parent) | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
# 直接打包源码，许可证以额外条目加入，不修改工作树、不复制临时目录。
$archive = [System.IO.Compression.ZipArchive]::new([System.IO.File]::Open($output,[System.IO.FileMode]::Create),[System.IO.Compression.ZipArchiveMode]::Create)
try {
  $src = Join-Path $root 'src'
  Get-ChildItem $src -File -Recurse | ForEach-Object {
    $entry = [System.IO.Path]::GetRelativePath($src,$_.FullName).Replace('\','/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$_.FullName,$entry) | Out-Null
  }
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $root 'LICENSE'),'zhi_axis_inspector/LICENSE.txt') | Out-Null
} finally { $archive.Dispose() }
Get-Item $output | Select-Object FullName,Length
