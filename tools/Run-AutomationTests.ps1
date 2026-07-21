[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $DwarfSpecArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Reads one required project-local environment variable from a dotenv file.

.PARAMETER EnvironmentPath
The dotenv file to read.

.PARAMETER Name
The required variable name.

.OUTPUTS
The nonempty variable value.
#>
function Get-ProjectEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $EnvironmentPath,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Leaf)) {
        throw "Local environment file was not found: $EnvironmentPath. Copy .env.example to .env and set $Name."
    }

    $value = $null
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $EnvironmentPath) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $match = [regex]::Match($trimmed,
            '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
        if (-not $match.Success) {
            throw "Malformed dotenv assignment at $EnvironmentPath`:$lineNumber."
        }
        if ($match.Groups[1].Value -ne $Name) { continue }
        if ($null -ne $value) {
            throw "Duplicate $Name assignment in $EnvironmentPath."
        }
        $value = $match.Groups[2].Value.Trim()
        if ($value.Length -ge 2 -and
                (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                 ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Name must be set to a nonempty value in $EnvironmentPath."
    }
    return $value
}

<#
.SYNOPSIS
Resolves the supported dfhack-run bridge from its containing directory.

.PARAMETER DFHackRoot
The absolute directory that contains dfhack-run.exe.

.OUTPUTS
The dfhack-run executable path.
#>
function Resolve-DFHackRunner {
    param(
        [Parameter(Mandatory)]
        [string] $DFHackRoot
    )

    if (-not [System.IO.Path]::IsPathRooted($DFHackRoot)) {
        throw "DFHACK_ROOT must be an absolute path: $DFHackRoot."
    }
    if (-not (Test-Path -LiteralPath $DFHackRoot -PathType Container)) {
        throw "DFHACK_ROOT directory was not found: $DFHackRoot."
    }
    $runner = Join-Path $DFHackRoot 'dfhack-run.exe'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "DFHACK_ROOT does not contain dfhack-run.exe: $DFHackRoot."
    }
    return $runner
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$environmentPath = Join-Path $projectRoot '.env'
$dfhackRoot = Get-ProjectEnvironmentValue $environmentPath 'DFHACK_ROOT'
$runner = Resolve-DFHackRunner $dfhackRoot
$launcher = Join-Path $projectRoot 'bin\dwarfspec'

if (-not (Get-Command lua -ErrorAction SilentlyContinue)) {
    throw 'Lua was not found on PATH.'
}
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "DwarfSpec source launcher was not found: $launcher."
}

$oldDFHackRoot = [Environment]::GetEnvironmentVariable('DFHACK_ROOT', 'Process')
$oldDFHackRunner = [Environment]::GetEnvironmentVariable('DFHACK_RUNNER', 'Process')
$locationPushed = $false
$runArguments = @('run')
$hasTestGlob = $false
foreach ($argument in $DwarfSpecArgs) {
    if ($argument -eq '--test-glob' -or
            $argument.StartsWith('--test-glob=')) {
        $hasTestGlob = $true
        break
    }
}
if (-not $hasTestGlob) {
    $runArguments += @('--test-glob',
        'tests/automation/specs/*_live_spec.lua')
}
$runArguments += $DwarfSpecArgs
try {
    [Environment]::SetEnvironmentVariable('DFHACK_ROOT', $dfhackRoot, 'Process')
    [Environment]::SetEnvironmentVariable('DFHACK_RUNNER', $runner, 'Process')
    Push-Location -LiteralPath $projectRoot
    $locationPushed = $true
    & lua $launcher @runArguments
    $exitCode = $LASTEXITCODE
}
finally {
    if ($locationPushed) { Pop-Location -ErrorAction SilentlyContinue }
    [Environment]::SetEnvironmentVariable('DFHACK_ROOT', $oldDFHackRoot,
        'Process')
    [Environment]::SetEnvironmentVariable('DFHACK_RUNNER', $oldDFHackRunner,
        'Process')
}

if ($exitCode -ne 0) {
    throw "DwarfSpec live automation failed with exit code $exitCode."
}
