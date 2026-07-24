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

$rockspecPath = $rockspecFiles[0].FullName
$rockspec = Get-Content -LiteralPath $rockspecPath -Raw
$packageMatch = [regex]::Match(
    $rockspec,
    '(?m)^\s*package\s*=\s*["'']([^"'']+)["'']\s*$')
$versionMatch = [regex]::Match(
    $rockspec,
    '(?m)^\s*version\s*=\s*["'']([^"'']+)["'']\s*$')
if (-not $packageMatch.Success -or -not $versionMatch.Success) {
    throw 'The release rockspec must declare literal package and version values.'
}
$packageName = $packageMatch.Groups[1].Value
$packageVersion = $versionMatch.Groups[1].Value
$artifactStem = [IO.Path]::GetFileNameWithoutExtension(
    $rockspecFiles[0].Name)
$artifactPath = Join-Path $projectRoot "dist\$artifactStem.all.rock"
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "Locally built package was not found: $artifactPath"
}

& luarocks show $packageName $packageVersion *> $null
if ($LASTEXITCODE -eq 0) {
    $removeOutput = & luarocks remove $packageName $packageVersion `
        --force-fast 2>&1
    $removeExitCode = $LASTEXITCODE
    if ($removeExitCode -ne 0) {
        & luarocks show $packageName $packageVersion *> $null
        if ($LASTEXITCODE -eq 0) {
            $removeOutput | Write-Host
            throw "LuaRocks failed to remove the existing locally built package."
        }
    }
}

& luarocks install $artifactPath --force-fast
if ($LASTEXITCODE -ne 0) {
    throw "LuaRocks failed to install the locally built package."
}

Write-Host "Installed $artifactPath"
