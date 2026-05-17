$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$HugoExe = Join-Path $Root "tools/hugo/hugo.exe"
$DartSassDir = Join-Path $Root "tools/dart-sass/dart-sass"
if (-not (Test-Path $HugoExe)) { throw "Hugo not found: $HugoExe" }
if (-not (Test-Path (Join-Path $DartSassDir "sass.bat"))) { throw "Dart Sass not found: $DartSassDir" }
$env:PATH = "$DartSassDir;$env:PATH"
Set-Location (Join-Path $Root "方案A-Hugo-FixIt")
& $HugoExe server -D