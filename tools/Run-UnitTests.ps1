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

$testsRoot = Join-Path $projectRoot 'tests\unit'

$oldLuaPath = [Environment]::GetEnvironmentVariable('LUA_PATH', 'Process')
$oldLuaCPath = [Environment]::GetEnvironmentVariable('LUA_CPATH', 'Process')
try {
    $luaPath = & luarocks path --tree $rockTree --lr-path
    if ($LASTEXITCODE -ne 0) {
        throw 'LuaRocks failed to calculate LUA_PATH.'
    }
    if ($null -ne $oldLuaPath) { $luaPath += ";$oldLuaPath" }
    Set-Item -LiteralPath Env:LUA_PATH -Value $luaPath

    $luaCPath = & luarocks path --tree $rockTree --lr-cpath
    if ($LASTEXITCODE -ne 0) {
        throw 'LuaRocks failed to calculate LUA_CPATH.'
    }
    if ($null -ne $oldLuaCPath) { $luaCPath += ";$oldLuaCPath" }
    Set-Item -LiteralPath Env:LUA_CPATH -Value $luaCPath

    $bustedRockDir = & luarocks show busted $bustedVersion `
        --tree $rockTree `
        --rock-dir
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($bustedRockDir)) {
        throw 'LuaRocks failed to locate the installed Busted package.'
    }

    # The deployed bin launcher is platform-specific; this is Busted's Lua source.
    $bustedRunner = Join-Path $bustedRockDir.Trim() 'bin/busted'
    if (-not (Test-Path -LiteralPath $bustedRunner -PathType Leaf)) {
        throw "Busted's Lua runner was not found at '$bustedRunner'."
    }

    & lua $bustedRunner '--defer-print' '-o' 'plainTerminal' `
        @BustedArgs '--no-recursive' $testsRoot
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
