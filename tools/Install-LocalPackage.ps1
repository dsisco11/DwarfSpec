[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rockspecFiles = @(Get-ChildItem -LiteralPath $projectRoot -File `
    -Filter '*.rockspec')
if ($rockspecFiles.Count -ne 1) {
    throw "Expected exactly one root rockspec; found $($rockspecFiles.Count)."
}
if (-not (Get-Command luarocks -ErrorAction SilentlyContinue)) {
    throw 'LuaRocks was not found on PATH.'
}

$artifactStem = [IO.Path]::GetFileNameWithoutExtension(
    $rockspecFiles[0].Name)
$artifactPath = Join-Path $projectRoot "dist\$artifactStem.all.rock"
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "Locally built package was not found: $artifactPath"
}

& luarocks install $artifactPath --force
if ($LASTEXITCODE -ne 0) {
    throw "LuaRocks failed to install the locally built package."
}

Write-Host "Installed $artifactPath"
