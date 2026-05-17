$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$MkDocsRoot = Join-Path $Root "方案B-MkDocs-Material"
$HugoRoot = Join-Path $Root "方案A-Hugo-FixIt"
$HugoExe = Join-Path $Root "tools/hugo/hugo.exe"
$DartSassDir = Join-Path $Root "tools/dart-sass/dart-sass"

Write-Host "Checking MkDocs Material..."
Set-Location $MkDocsRoot
python -m pip show mkdocs-material | Out-Null

Write-Host "Checking Hugo..."
if (-not (Test-Path $HugoExe)) { throw "Hugo not found: $HugoExe" }
& $HugoExe version

Write-Host "Checking FixIt theme..."
if (-not (Test-Path (Join-Path $HugoRoot "themes/FixIt"))) { throw "FixIt theme not found." }

Write-Host "Checking Dart Sass..."
if (-not (Test-Path (Join-Path $DartSassDir "sass.bat"))) { throw "Dart Sass not found." }
& (Join-Path $DartSassDir "sass.bat") --version

Write-Host "All dependencies are ready."