[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $BustedArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$rockTree = Join-Path $projectRoot '.luarocks'
$bustedVersion = '2.3.0-1'
$luaSystemVersion = '0.3.0-2'

if (-not (Get-Command lua -ErrorAction SilentlyContinue)) {
    throw 'Lua was not found on PATH.'
}
if (-not (Get-Command luarocks -ErrorAction SilentlyContinue)) {
    throw 'LuaRocks was not found on PATH.'
}

$luaCommand = Get-Command lua
$luaVersionText = & $luaCommand.Source -e "io.write(_VERSION)"
$luaVersionMatch = [regex]::Match($luaVersionText, '^Lua ([0-9]+\.[0-9]+)$')
if ($LASTEXITCODE -ne 0 -or -not $luaVersionMatch.Success) {
    throw "Could not determine the Lua version; found '$luaVersionText'."
}
$luaVersion = $luaVersionMatch.Groups[1].Value
$rockLuaVersion = & luarocks config lua_version
if ($LASTEXITCODE -ne 0 -or $rockLuaVersion.Trim() -ne $luaVersion) {
    throw "LuaRocks targets Lua '$rockLuaVersion', but the active interpreter is Lua $luaVersion."
}

& luarocks show luasystem $luaSystemVersion --tree $rockTree *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing LuaSystem $luaSystemVersion into .luarocks..."
    & luarocks install luasystem $luaSystemVersion --tree $rockTree
    if ($LASTEXITCODE -ne 0) {
        throw "LuaRocks failed to install LuaSystem $luaSystemVersion."
    }
}

& luarocks show busted $bustedVersion --tree $rockTree *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing Busted $bustedVersion into .luarocks..."
    & luarocks install busted $bustedVersion --tree $rockTree
    if ($LASTEXITCODE -ne 0) {
        throw "LuaRocks failed to install Busted $bustedVersion."
    }
}

$testFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tests') -Recurse -File |
        Where-Object { $_.Name -match '(^test_.*|.*_test)\.lua$' } |
        Sort-Object FullName |
        ForEach-Object FullName
)
if ($testFiles.Count -eq 0) {
    throw 'No unit-test files were found.'
}

$oldLuaPath = [Environment]::GetEnvironmentVariable('LUA_PATH', 'Process')
$oldLuaCPath = [Environment]::GetEnvironmentVariable('LUA_CPATH', 'Process')
try {
    $luaPath = @(
        (Join-Path $rockTree "share\lua\$luaVersion\?.lua"),
        (Join-Path $rockTree "share\lua\$luaVersion\?\init.lua")
    ) -join ';'
    if ($null -ne $oldLuaPath) { $luaPath += ";$oldLuaPath" }
    Set-Item -LiteralPath Env:LUA_PATH -Value $luaPath

    $luaCPath = Join-Path $rockTree "lib\lua\$luaVersion\?.dll"
    if ($null -ne $oldLuaCPath) { $luaCPath += ";$oldLuaCPath" }
    Set-Item -LiteralPath Env:LUA_CPATH -Value $luaCPath

    $bustedLauncher = Join-Path $rockTree 'bin\busted'
    & lua $bustedLauncher @BustedArgs @testFiles
    $testExitCode = $LASTEXITCODE
}
finally {
    if ($null -eq $oldLuaPath) {
        Remove-Item -LiteralPath Env:LUA_PATH -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath Env:LUA_PATH -Value $oldLuaPath
    }
    if ($null -eq $oldLuaCPath) {
        Remove-Item -LiteralPath Env:LUA_CPATH -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath Env:LUA_CPATH -Value $oldLuaCPath
    }
}

if ($testExitCode -ne 0) {
    throw "Busted tests failed with exit code $testExitCode."
}
