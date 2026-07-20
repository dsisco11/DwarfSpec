[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command luac -ErrorAction SilentlyContinue)) {
    throw 'Lua 5.3 compiler was not found on PATH.'
}

$compiler = Get-Command luac
$version = (& $compiler.Source -v 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Lua 5\.3') {
    throw "DwarfSpec requires Lua 5.3; found '$version'."
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$luaFiles = @(
    Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*.lua' |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.luarocks[\\/]' -and
            $_.FullName -notmatch '[\\/]\.package-[^\\/]+[\\/]'
        } |
        Sort-Object FullName
)

if ($luaFiles.Count -eq 0) {
    throw 'No Lua files were found.'
}

foreach ($file in $luaFiles) {
    & $compiler.Source -p $file.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Lua 5.3 syntax check failed: $($file.FullName)"
    }

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -eq 0 -or $bytes[$bytes.Length - 1] -ne 10) {
        throw "Lua file must end with a newline: $($file.FullName)"
    }

    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        $lineNumber++
        if ($line.Contains("`t")) {
            throw "Lua file contains a tab at $($file.FullName):$lineNumber"
        }
        if ($line -match '[ ]+$') {
            throw "Lua file has trailing whitespace at $($file.FullName):$lineNumber"
        }
    }
}

Write-Host "Lua 5.3 syntax and formatting checks passed for $($luaFiles.Count) files."
