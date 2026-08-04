[CmdletBinding()]
param(
    [ValidateSet('Valid', 'Invalid')]
    [string] $Mode = 'Valid'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Find-LuaLanguageServer {
    $command = Get-Command lua-language-server -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
    $candidate = Get-ChildItem -LiteralPath $extensionRoot -Recurse -File `
        -Filter 'lua-language-server.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    throw 'Lua language server was not found on PATH or in VS Code extensions.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $projectRoot ('tests\declarations\' + $Mode.ToLowerInvariant())
if (-not (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
    throw "Declaration fixture directory was not found: $fixtureRoot"
}
$temporaryConfig = New-TemporaryFile
try {
    $sourceRoot = $projectRoot.Replace('\', '/')
    $config = @{
        'runtime.version' = 'Lua 5.4'
        'workspace.library' = @(
            "$sourceRoot/src/ds.d.lua",
            "$sourceRoot/src"
        )
        'workspace.checkThirdParty' = $false
        'diagnostics.disable' = @('lowercase-global')
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($temporaryConfig, $config)
    $logPath = Join-Path $env:TEMP ('dwarfspec-luals-' + $Mode.ToLowerInvariant())
    $output = & (Find-LuaLanguageServer) "--check=$fixtureRoot" `
        "--configpath=$temporaryConfig" '--checklevel=Warning' `
        "--logpath=$logPath" 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output | Out-String
    if ($Mode -eq 'Valid') {
        if ($exitCode -ne 0) { throw "Valid declaration fixtures failed:`n$text" }
        Write-Host 'Valid source declaration fixtures passed.'
        exit 0
    }
    if ($exitCode -eq 0) { throw 'Invalid declaration fixtures produced no diagnostics.' }
    foreach ($expected in @('dwarfspec.TestBed', 'dwarfspec.ModuleComponentSource',
            'component_imports', 'testbed_unknown_strategy.lua')) {
        if (-not $text.Contains($expected)) {
            throw "Invalid declaration diagnostics omitted expected text: $expected`n$text"
        }
    }
    Write-Host 'Invalid source declaration fixtures produced expected static diagnostics.'
    exit 0
}
finally {
    Remove-Item -LiteralPath $temporaryConfig -Force -ErrorAction SilentlyContinue
}
