$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$MkDocsRoot = Join-Path $Root "方案B-MkDocs-Material"
$LinkRoot = "F:\kimicode\vcp-knowledge-mkdocs"
$SiteDir = Join-Path $LinkRoot "site"

if (-not (Test-Path $LinkRoot)) {
  cmd /c mklink /J $LinkRoot $MkDocsRoot | Out-Null
}

Set-Location $LinkRoot
python -m mkdocs build --clean
python -m http.server 8000 --bind 127.0.0.1 --directory $SiteDir