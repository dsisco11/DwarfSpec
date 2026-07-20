[CmdletBinding()]
param(
    [string] $LuaCommand = $env:LUA53
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($LuaCommand)) {
    $candidate = Get-Command lua5.3 -ErrorAction SilentlyContinue
    if ($null -eq $candidate) {
        throw 'Lua 5.3 was not found. Pass -LuaCommand or set LUA53.'
    }
    $LuaCommand = $candidate.Source
}

$version = & $LuaCommand -e 'io.write(_VERSION)'
if ($LASTEXITCODE -ne 0 -or $version -ne 'Lua 5.3') {
    throw "Lua 5.3 is required for the compatibility gate; found '$version'."
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$luaFiles = @(
    Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter '*.lua' |
        Where-Object { $_.FullName -notmatch '[\\/]\.luarocks[\\/]' } |
        Sort-Object FullName
)

if ($luaFiles.Count -eq 0) {
    throw 'No Lua files were found.'
}

foreach ($file in $luaFiles) {
    & $LuaCommand -e 'assert(loadfile(arg[1]))' $file.FullName
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
