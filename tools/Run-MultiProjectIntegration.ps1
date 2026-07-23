[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int] $Iterations = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$evidencePath = Join-Path $projectRoot `
    'tests\.test-results\dwarfspec\multi-project-evidence.json'
$knownRunIds = [System.Collections.Generic.List[string]]::new()
$processes = [System.Collections.Generic.List[object]]::new()
$evidence = [ordered]@{
    schema = 'dwarfspec.multi-project-evidence.v1'
    started_at = [DateTime]::UtcNow.ToString('o')
    iterations = $Iterations
    scenarios = [System.Collections.Generic.List[object]]::new()
    failure = $null
}

<#
.SYNOPSIS
Reads one required value from a project-local dotenv file.

.PARAMETER Path
The dotenv file path.

.PARAMETER Name
The required variable name.

.OUTPUTS
The nonempty configured string.
#>
function Get-ProjectEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        $match = [regex]::Match($line.Trim(),
            '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
        if (-not $match.Success -or $match.Groups[1].Value -ne $Name) {
            continue
        }
        if ($null -ne $value) { throw "Duplicate $Name assignment in $Path." }
        $value = $match.Groups[2].Value.Trim().Trim('"').Trim("'")
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Name must be set in $Path."
    }
    return $value
}

<#
.SYNOPSIS
Starts one process with asynchronous redirected output capture.

.PARAMETER FilePath
The executable path or command name.

.PARAMETER Arguments
The exact argument vector.

.OUTPUTS
A captured process handle.
#>
function Start-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start process: $FilePath"
    }
    $handle = [pscustomobject]@{
        Process = $process
        StandardOutput = $process.StandardOutput.ReadToEndAsync()
        StandardError = $process.StandardError.ReadToEndAsync()
        FilePath = $FilePath
        Arguments = $Arguments
    }
    $processes.Add($handle)
    return $handle
}

<#
.SYNOPSIS
Completes one captured process and validates its classified exit code.

.PARAMETER Handle
The process handle returned by Start-CapturedProcess.

.PARAMETER ExpectedExitCodes
The allowed process exit codes.

.PARAMETER TimeoutSeconds
The bounded process wait.

.OUTPUTS
One immutable process result object.
#>
function Complete-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [object] $Handle,
        [int[]] $ExpectedExitCodes = @(0),
        [int] $TimeoutSeconds = 60
    )

    if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
        $Handle.Process.Kill($true)
        throw "Process timed out after $TimeoutSeconds seconds: $($Handle.FilePath)"
    }
    $stdout = $Handle.StandardOutput.GetAwaiter().GetResult()
    $stderr = $Handle.StandardError.GetAwaiter().GetResult()
    $result = [pscustomobject]@{
        ExitCode = $Handle.Process.ExitCode
        StandardOutput = $stdout
        StandardError = $stderr
        Lines = @(
            ($stdout -split '\r?\n') | Where-Object { $_ -ne '' }
        )
    }
    if ($ExpectedExitCodes -notcontains $result.ExitCode) {
        $detail = ($stdout + "`n" + $stderr).Trim()
        if ($detail.Length -gt 2048) { $detail = $detail.Substring(0, 2048) }
        throw "Unexpected exit $($result.ExitCode) from $($Handle.FilePath): $detail"
    }
    return $result
}

<#
.SYNOPSIS
Runs one captured process synchronously.

.PARAMETER FilePath
The executable path or command name.

.PARAMETER Arguments
The exact argument vector.

.PARAMETER ExpectedExitCodes
The allowed process exit codes.

.OUTPUTS
One process result object.
#>
function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [string[]] $Arguments,
        [int[]] $ExpectedExitCodes = @(0)
    )

    $handle = Start-CapturedProcess -FilePath $FilePath -Arguments $Arguments
    return Complete-CapturedProcess -Handle $handle `
        -ExpectedExitCodes $ExpectedExitCodes
}

<#
.SYNOPSIS
Parses exactly one canonical transport response.

.PARAMETER Result
The captured process result.

.OUTPUTS
The decoded transport object.
#>
function Get-CanonicalTransport {
    param([Parameter(Mandatory)][object] $Result)

    $payloads = @($Result.Lines | Where-Object {
        $_.StartsWith('DWARFSPEC_JSON ')
    })
    if ($payloads.Count -ne 1) {
        throw "Expected one canonical transport response, found $($payloads.Count)."
    }
    return $payloads[0].Substring(15) | ConvertFrom-Json -Depth 100
}

<#
.SYNOPSIS
Parses exactly one integration-control response.

.PARAMETER Result
The captured process result.

.OUTPUTS
The decoded control object.
#>
function Get-HarnessResponse {
    param([Parameter(Mandatory)][object] $Result)

    $prefix = 'DWARFSPEC_HARNESS_JSON '
    $payloads = @($Result.Lines | Where-Object { $_.StartsWith($prefix) })
    if ($payloads.Count -ne 1) {
        throw "Expected one harness response, found $($payloads.Count)."
    }
    return $payloads[0].Substring($prefix.Length) |
        ConvertFrom-Json -Depth 100
}

$environmentPath = Join-Path $projectRoot '.env'
$dfhackRoot = Get-ProjectEnvironmentValue -Path $environmentPath `
    -Name 'DFHACK_ROOT'
$dfhackRunner = Join-Path $dfhackRoot 'dfhack-run.exe'
$launcher = Join-Path $projectRoot 'bin\dwarfspec'
$controlScript = Join-Path $projectRoot `
    'tests\integration\support\control.lua'
$scenarioRunner = Join-Path $projectRoot `
    'tests\integration\support\scenario_runner.lua'
$bootstrapScript = Join-Path $projectRoot `
    'tests\automation\support\bootstrap.lua'
$abortScript = Join-Path $projectRoot 'tests\automation\support\abort.lua'
$discardScript = Join-Path $projectRoot 'tests\automation\support\discard.lua'
$recoverExecutorScript = Join-Path $projectRoot `
    'tests\automation\support\recover_executor.lua'
$luaModuleRoot = Join-Path $projectRoot '.luarocks\share\lua\5.4'

if (-not (Test-Path -LiteralPath $dfhackRunner -PathType Leaf)) {
    throw "DFHACK_ROOT does not contain dfhack-run.exe: $dfhackRoot"
}

$alphaRoot = Join-Path $projectRoot `
    'tests\framework\service_project_alpha'
$betaRoot = Join-Path $projectRoot `
    'tests\framework\service project beta'
$gammaRoot = Join-Path $projectRoot `
    'tests\framework\service_project_gamma'
$commandRoot = Join-Path $projectRoot `
    'tests\framework\command_project'

<#
.SYNOPSIS
Throws when an integration invariant is false.

.PARAMETER Condition
The required truth value.

.PARAMETER Message
The actionable failure message.
#>
function Assert-Integration {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,
        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

<#
.SYNOPSIS
Returns the stable default result path for one project.

.PARAMETER Project
The consumer project root.

.OUTPUTS
The exact default result file path.
#>
function Get-DefaultResultPath {
    param([Parameter(Mandatory)][string] $Project)

    return Join-Path $Project 'tests\.test-results\dwarfspec\results.json'
}

<#
.SYNOPSIS
Starts one project-local DwarfSpec run through the public CLI.

.PARAMETER Project
The consumer project root.

.PARAMETER RunId
The explicit integration run identifier.

.PARAMETER TestGlob
The exact project discovery glob.

.PARAMETER ResultPath
An optional exact result path.

.PARAMETER TimeoutSeconds
The execution timeout.

.OUTPUTS
A captured process handle.
#>
function Start-DwarfSpecRun {
    param(
        [Parameter(Mandatory)]
        [string] $Project,
        [Parameter(Mandatory)]
        [string] $RunId,
        [string] $TestGlob = 'tests/live/shared_spec.ds.lua',
        [string] $ResultPath,
        [double] $TimeoutSeconds = 10
    )

    $arguments = @(
        $launcher,
        'run',
        "--project-root=$Project",
        "--test-glob=$TestGlob",
        "--run-id=$RunId",
        "--timeout=$TimeoutSeconds",
        '--queue-timeout=30',
        '--poll-interval-ms=25'
    )
    if ($ResultPath) { $arguments += "--results=$ResultPath" }
    $knownRunIds.Add($RunId)
    return Start-CapturedProcess -FilePath 'lua' -Arguments $arguments
}

<#
.SYNOPSIS
Runs one project-local DwarfSpec command synchronously.

.PARAMETER Project
The consumer project root.

.PARAMETER RunId
The explicit integration run identifier.

.PARAMETER TestGlob
The exact project discovery glob.

.PARAMETER ResultPath
The exact result path.

.PARAMETER ExpectedExitCode
The expected classified exit code.

.PARAMETER TimeoutSeconds
The external execution timeout.

.OUTPUTS
The captured process result.
#>
function Invoke-DwarfSpecRun {
    param(
        [Parameter(Mandatory)]
        [string] $Project,
        [Parameter(Mandatory)]
        [string] $RunId,
        [Parameter(Mandatory)]
        [string] $TestGlob,
        [Parameter(Mandatory)]
        [string] $ResultPath,
        [Parameter(Mandatory)]
        [int] $ExpectedExitCode,
        [double] $TimeoutSeconds = 10
    )

    $handle = Start-DwarfSpecRun -Project $Project -RunId $RunId `
        -TestGlob $TestGlob -ResultPath $ResultPath `
        -TimeoutSeconds $TimeoutSeconds
    return Complete-CapturedProcess -Handle $handle `
        -ExpectedExitCodes @($ExpectedExitCode)
}

<#
.SYNOPSIS
Invokes one source transport adapter through dfhack-run.

.PARAMETER Script
The adapter path.

.PARAMETER Arguments
The adapter arguments.

.PARAMETER ExpectedExitCodes
The accepted bridge exit codes.

.OUTPUTS
The captured bridge result.
#>
function Invoke-BridgeScript {
    param(
        [Parameter(Mandatory)]
        [string] $Script,
        [string[]] $Arguments = @(),
        [int[]] $ExpectedExitCodes = @(0)
    )

    $bridgeArguments = @(
        'lua', '-f', $Script
    ) + $Arguments
    return Invoke-CapturedProcess -FilePath $dfhackRunner `
        -Arguments $bridgeArguments -ExpectedExitCodes $ExpectedExitCodes
}

<#
.SYNOPSIS
Reads one run and raw host-resource snapshot without renewing its lease.

.PARAMETER RunId
The service-assigned run identifier.

.PARAMETER Cursor
The event cursor.

.OUTPUTS
The decoded transport with integration diagnostics.
#>
function Get-RunSnapshot {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,
        [int] $Cursor = 0
    )

    $result = Invoke-BridgeScript -Script $controlScript -Arguments @(
        'snapshot', $RunId, [string]$Cursor
    )
    return Get-CanonicalTransport -Result $result
}

<#
.SYNOPSIS
Reads the resident service registry without changing service state.

.OUTPUTS
The bounded integration registry diagnostic.
#>
function Get-ServiceRegistry {
    $result = Invoke-BridgeScript -Script $controlScript -Arguments @(
        'registry'
    )
    return (Get-HarnessResponse -Result $result).registry
}

<#
.SYNOPSIS
Returns stale harness-owned results for the integration fixture projects.

.OUTPUTS
The matching hardening-run identifiers.
#>
function Get-StaleFixtureRunIds {
    $fixtureIdentities = @(
        $alphaRoot, $betaRoot, $gammaRoot
    ) | ForEach-Object {
        ([IO.Path]::GetFullPath($_) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    }
    $registry = Get-ServiceRegistry
    return @($registry.projects | Where-Object {
        $identity = ([string]$_.normalized_project_root).
            TrimEnd('/').ToLowerInvariant()
        $null -ne $_.outstanding_run_id -and
            ([string]$_.outstanding_run_id).StartsWith('hardening-') -and
            $fixtureIdentities -contains $identity
    } | ForEach-Object { [string]$_.outstanding_run_id })
}

<#
.SYNOPSIS
Waits for one run to reach any requested service state.

.PARAMETER RunId
The service run identifier.

.PARAMETER States
The accepted states.

.PARAMETER TimeoutSeconds
The bounded wait.

.OUTPUTS
The matching transport snapshot.
#>
function Wait-RunState {
    param(
        [Parameter(Mandatory)]
        [string] $RunId,
        [Parameter(Mandatory)]
        [string[]] $States,
        [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastFailure = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $transport = Get-RunSnapshot -RunId $RunId
            if ($States -contains $transport.snapshot.state) {
                return $transport
            }
        } catch {
            $lastFailure = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 25
    }
    throw "Run $RunId did not reach [$($States -join ', ')]: $lastFailure"
}

<#
.SYNOPSIS
Reads and validates one exact persisted result file.

.PARAMETER Path
The result file path.

.PARAMETER RunId
The expected run identifier.

.OUTPUTS
The decoded version 2 result.
#>
function Read-RunResult {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $RunId
    )

    Assert-Integration (Test-Path -LiteralPath $Path -PathType Leaf) `
        "Result file was not written: $Path"
    $result = Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 100
    Assert-Integration ($result.schema -eq 'dwarfspec.result.v2') `
        "Unexpected result schema at $Path"
    Assert-Integration ($result.run_id -eq $RunId) `
        "Stale result file at $Path; expected $RunId, found $($result.run_id)"
    return $result
}

<#
.SYNOPSIS
Returns one event of an exact type from a persisted journal.

.PARAMETER Result
The decoded persisted result.

.PARAMETER Type
The event identifier.

.OUTPUTS
The matching event.
#>
function Get-ResultEvent {
    param(
        [Parameter(Mandatory)]
        [object] $Result,
        [Parameter(Mandatory)]
        [string] $Type
    )

    $event = @($Result.events | Where-Object { $_.type -eq $Type }) |
        Select-Object -First 1
    if ($null -eq $event) {
        throw "Run $($Result.run_id) did not retain event $Type."
    }
    return $event
}

<#
.SYNOPSIS
Asserts that one terminal raw host generation owns no live resources.

.PARAMETER Transport
The integration snapshot transport.
#>
function Assert-CleanRun {
    param([Parameter(Mandatory)][object] $Transport)

    $raw = $Transport.harness.run
    Assert-Integration $raw.terminal 'Raw run is not terminal.'
    Assert-Integration ($raw.cleanup_pending -eq 0) `
        'Cleanup registry still owns pending actions.'
    Assert-Integration (-not $raw.cleanup_running) `
        'Cleanup registry is still running.'
    Assert-Integration (-not $raw.coroutine_active) `
        'Run coroutine remains active.'
    Assert-Integration (-not $raw.scheduler_active) `
        'Run scheduler remains active.'
    Assert-Integration (-not $raw.wait_active) 'Run wait remains active.'
    Assert-Integration (-not $raw.timer_active) 'Run timer remains active.'
    Assert-Integration (-not $raw.mount_probe_active) `
        'Run mount probe remains active.'
    if ($null -ne $raw.mount_cleanup_state) {
        Assert-Integration ($raw.mount_cleanup_state.active_screen_count -eq 0) `
            'A run-owned screen remains active.'
        Assert-Integration ($raw.mount_cleanup_state.subject_count -eq 0) `
            'A run-owned subject remains active.'
        Assert-Integration (-not $raw.mount_cleanup_state.pointer_active) `
            'A run-owned pointer remains active.'
    }
    if ($null -ne $raw.module_environment_audit) {
        Assert-Integration $raw.module_environment_audit.restored `
            'Project modules were not restored.'
        Assert-Integration $raw.module_environment_audit.path_restored `
            'Project package.path was not restored.'
    }
}

<#
.SYNOPSIS
Starts one run directly without an external owner poll loop.

.PARAMETER Project
The project root.

.PARAMETER RunId
The explicit run identifier.

.PARAMETER LeaseMilliseconds
The queue and execution lease duration.

.PARAMETER Spec
The project-relative spec path.

.OUTPUTS
The bootstrap transport.
#>
function Invoke-ManualBootstrap {
    param(
        [Parameter(Mandatory)]
        [string] $Project,
        [Parameter(Mandatory)]
        [string] $RunId,
        [int] $LeaseMilliseconds = 5000,
        [string] $Spec = 'live/shared_spec.ds.lua'
    )

    $knownRunIds.Add($RunId)
    $result = Invoke-BridgeScript -Script $bootstrapScript -Arguments @(
        $RunId,
        "--project-root=$Project",
        '--repeat=1',
        '--defer-frames=1',
        "--lease-timeout-ms=$LeaseMilliseconds",
        '--lease-check-frames=1',
        "--test-glob=tests/$Spec",
        "--lua-module-root=$luaModuleRoot",
        '--result-policy=none',
        "--spec=$Spec"
    )
    return Get-CanonicalTransport -Result $result
}

<#
.SYNOPSIS
Discards one exact unacknowledged terminal run.

.PARAMETER Transport
The current terminal transport.

.PARAMETER Reason
The bounded operator reason.
#>
function Invoke-Discard {
    param(
        [Parameter(Mandatory)]
        [object] $Transport,
        [Parameter(Mandatory)]
        [string] $Reason
    )

    [void](Invoke-BridgeScript -Script $discardScript -Arguments @(
        $Transport.run_id,
        [string]$Transport.generation,
        [string]$Transport.last_sequence,
        $Reason
    ))
}

<#
.SYNOPSIS
Recovers one exact quarantined executor generation.

.PARAMETER Transport
The quarantined terminal run transport.

.PARAMETER Reason
The bounded recovery reason.

.OUTPUTS
The recovered transport and scheduler.
#>
function Invoke-ExecutorRecovery {
    param(
        [Parameter(Mandatory)]
        [object] $Transport,
        [Parameter(Mandatory)]
        [string] $Reason
    )

    $result = Invoke-BridgeScript -Script $recoverExecutorScript -Arguments @(
        $Transport.run_id,
        [string]$Transport.generation,
        [string]$Transport.last_sequence,
        $Reason
    )
    return Get-CanonicalTransport -Result $result
}

<#
.SYNOPSIS
Creates a stable per-scenario result path beneath one project.

.PARAMETER Project
The consumer project root.

.PARAMETER Name
The stable scenario name.

.OUTPUTS
The exact result path.
#>
function Get-ScenarioResultPath {
    param(
        [Parameter(Mandatory)]
        [string] $Project,
        [Parameter(Mandatory)]
        [string] $Name
    )

    return Join-Path $Project `
        "tests\.test-results\dwarfspec\hardening-$Name.json"
}

<#
.SYNOPSIS
Records one successful scenario evidence object.

.PARAMETER Name
The scenario name.

.PARAMETER Data
The bounded JSON-safe evidence.
#>
function Add-ScenarioEvidence {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [object] $Data
    )

    $evidence.scenarios.Add([ordered]@{
        name = $Name
        passed = $true
        evidence = $Data
    })
}

<#
.SYNOPSIS
Best-effort aborts, recovers, and releases one harness-owned run.

.PARAMETER RunId
The exact run identifier to repair.
#>
function Repair-RunState {
    param([Parameter(Mandatory)][string] $RunId)

    try {
        $transport = Get-RunSnapshot -RunId $RunId
        if (-not $transport.snapshot.terminal) {
            [void](Invoke-BridgeScript -Script $abortScript -Arguments @(
                $RunId, '', '0'
            ))
            $transport = Get-RunSnapshot -RunId $RunId
        }
        if ($transport.harness.registry.quarantine.active) {
            try {
                $transport = Invoke-ExecutorRecovery `
                    -Transport $transport `
                    -Reason 'integration harness failure recovery'
            } catch {}
        }
        $transport = Get-RunSnapshot -RunId $RunId
        if (-not $transport.snapshot.acknowledged -and
                -not $transport.snapshot.discarded) {
            try {
                Invoke-Discard -Transport $transport `
                    -Reason 'integration harness retained-state cleanup'
            } catch {}
        }
    } catch {}
}

<#
.SYNOPSIS
Best-effort cleanup for known integration generations.
#>
function Repair-IntegrationState {
    foreach ($handle in $processes) {
        if (-not $handle.Process.HasExited) {
            try {
                $handle.Process.Kill($true)
                [void]$handle.Process.WaitForExit(5000)
            } catch {}
        }
    }
    $repairRunIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($knownRunId in $knownRunIds) {
        [void]$repairRunIds.Add($knownRunId)
    }
    try {
        foreach ($staleRunId in Get-StaleFixtureRunIds) {
            [void]$repairRunIds.Add($staleRunId)
        }
    } catch {}
    foreach ($repairRunId in $repairRunIds) {
        Repair-RunState -RunId $repairRunId
    }
}

$oldDFHackRoot = [Environment]::GetEnvironmentVariable(
    'DFHACK_ROOT', 'Process')
$oldDFHackRunner = [Environment]::GetEnvironmentVariable(
    'DFHACK_RUNNER', 'Process')

try {
    [Environment]::SetEnvironmentVariable(
        'DFHACK_ROOT', $dfhackRoot, 'Process')
    [Environment]::SetEnvironmentVariable(
        'DFHACK_RUNNER', $dfhackRunner, 'Process')

    Repair-IntegrationState

    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        $prefix = "hardening-$iteration-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"

        $alphaId = "$prefix-fifo-alpha"
        $betaId = "$prefix-fifo-beta"
        $gammaId = "$prefix-fifo-gamma"
        $alpha = Start-DwarfSpecRun -Project $alphaRoot -RunId $alphaId
        [void](Wait-RunState -RunId $alphaId -States @('starting', 'running'))
        $beta = Start-DwarfSpecRun -Project $betaRoot -RunId $betaId
        [void](Wait-RunState -RunId $betaId -States @('queued'))
        $gamma = Start-DwarfSpecRun -Project $gammaRoot -RunId $gammaId
        $queuedGamma = Wait-RunState -RunId $gammaId -States @('queued')
        $queuedView = Get-RunSnapshot -RunId $betaId
        Assert-Integration `
            ($queuedView.harness.registry.active_run_id -eq $alphaId) `
            'FIFO alpha run did not retain the executor.'
        Assert-Integration `
            (($queuedView.harness.registry.queue -join ',') -eq
                "$betaId,$gammaId") `
            'FIFO queue order did not match beta then gamma.'

        $reloadResult = Invoke-BridgeScript -Script $controlScript `
            -Arguments @('compatible-reload', $betaId, '0')
        $reload = Get-CanonicalTransport -Result $reloadResult
        Assert-Integration `
            ($reload.harness.registry.active_run_id -eq $alphaId) `
            'Compatible adapter reload replaced active service state.'
        Assert-Integration `
            (($reload.harness.registry.queue -join ',') -eq
                "$betaId,$gammaId") `
            'Compatible adapter reload changed queued service state.'
        $registeredBefore = $queuedView.harness.registry.projects |
            ConvertTo-Json -Depth 10 -Compress
        $registeredAfter = $reload.harness.registry.projects |
            ConvertTo-Json -Depth 10 -Compress
        Assert-Integration ($registeredBefore -eq $registeredAfter) `
            'Compatible adapter reload changed registered project state.'
        $retainedBefore =
            $queuedView.harness.registry.latest_terminal_results |
                ConvertTo-Json -Depth 10 -Compress
        $retainedAfter =
            $reload.harness.registry.latest_terminal_results |
                ConvertTo-Json -Depth 10 -Compress
        Assert-Integration ($retainedBefore -eq $retainedAfter) `
            'Compatible adapter reload changed retained terminal state.'

        $incompatibleResult = Invoke-BridgeScript -Script $controlScript `
            -Arguments @('incompatible', $betaId, '0')
        $incompatible = Get-HarnessResponse -Result $incompatibleResult
        Assert-Integration $incompatible.rejected `
            'Incompatible service bootstrap was not rejected.'
        Assert-Integration `
            ($incompatible.before.service_instance_id -eq
                $incompatible.after.service_instance_id) `
            'Incompatible client replaced the service instance.'
        Assert-Integration `
            ($incompatible.before.generation -eq
                $incompatible.after.generation) `
            'Incompatible client changed service generation.'
        Assert-Integration `
            (($incompatible.before.queue -join ',') -eq
                ($incompatible.after.queue -join ',')) `
            'Incompatible client changed FIFO state.'

        [void](Complete-CapturedProcess -Handle $alpha)
        [void](Complete-CapturedProcess -Handle $beta)
        [void](Complete-CapturedProcess -Handle $gamma)
        $alphaResult = Read-RunResult -Path (
            Get-DefaultResultPath $alphaRoot) -RunId $alphaId
        $betaResult = Read-RunResult -Path (
            Get-DefaultResultPath $betaRoot) -RunId $betaId
        $gammaResult = Read-RunResult -Path (
            Get-DefaultResultPath $gammaRoot) -RunId $gammaId
        $fifoResults = @($alphaResult, $betaResult, $gammaResult)
        foreach ($result in $fifoResults) {
            Assert-Integration ($result.state -eq 'passed') `
                "FIFO run $($result.run_id) did not pass."
            Assert-Integration `
                ($result.selection.identities.Count -eq 1 -and
                 $result.selection.identities[0] -eq
                    'tests/live/shared_spec.ds.lua') `
                "FIFO run $($result.run_id) used the wrong selection."
        }
        $intervals = @()
        foreach ($result in $fifoResults) {
            $activated = Get-ResultEvent -Result $result -Type 'run.activated'
            $finished = Get-ResultEvent -Result $result -Type 'run.finished'
            $intervals += [pscustomobject]@{
                RunId = $result.run_id
                Activated = [int64]$result.host_report.submitted_at_ms +
                    [int64]$activated.elapsed_ms
                Finished = [int64]$result.host_report.submitted_at_ms +
                    [int64]$finished.elapsed_ms
            }
        }
        Assert-Integration `
            ($intervals[1].Activated -ge $intervals[0].Finished) `
            'Beta executor interval overlapped alpha.'
        Assert-Integration `
            ($intervals[2].Activated -ge $intervals[1].Finished) `
            'Gamma executor interval overlapped beta.'
        $projectIds = @($fifoResults | ForEach-Object { $_.project_id } |
            Sort-Object -Unique)
        Assert-Integration ($projectIds.Count -eq 3) `
            'Concurrent project results did not retain independent identities.'
        foreach ($run in @($alphaId, $betaId, $gammaId)) {
            Assert-CleanRun -Transport (Get-RunSnapshot -RunId $run)
        }
        Add-ScenarioEvidence -Name "fifo-$iteration" -Data ([ordered]@{
            activation_order = @($intervals | ForEach-Object { $_.RunId })
            intervals = $intervals
            project_ids = $projectIds
            shared_identity = 'tests/live/shared_spec.ds.lua'
            compatible_reload_preserved = $true
            incompatible_client_rejected = $true
        })

        $activeId = "$prefix-cancel-active"
        $cancelId = "$prefix-cancel-queued"
        $active = Start-DwarfSpecRun -Project $alphaRoot -RunId $activeId
        [void](Wait-RunState -RunId $activeId -States @('starting', 'running'))
        $cancelled = Start-DwarfSpecRun -Project $betaRoot -RunId $cancelId
        [void](Wait-RunState -RunId $cancelId -States @('queued'))
        $beforeCancel = Get-RunSnapshot -RunId $activeId
        [void](Invoke-CapturedProcess -FilePath 'lua' -Arguments @(
            $launcher, 'abort', $cancelId, "--project-root=$betaRoot"
        ))
        [void](Complete-CapturedProcess -Handle $cancelled `
            -ExpectedExitCodes @(8))
        $afterCancel = Get-RunSnapshot -RunId $activeId
        Assert-Integration `
            ($afterCancel.snapshot.generation -eq
                $beforeCancel.snapshot.generation) `
            'Queued cancellation changed the active generation.'
        Assert-Integration `
            ($afterCancel.harness.registry.active_run_id -eq $activeId) `
            'Queued cancellation changed active ownership.'
        [void](Complete-CapturedProcess -Handle $active)
        $cancelResult = Read-RunResult -Path (
            Get-DefaultResultPath $betaRoot) -RunId $cancelId
        Assert-Integration ($cancelResult.state -eq 'cancelled') `
            'Queued CLI run did not retain cancellation classification.'
        $hasCancelledHostReport =
            $cancelResult.PSObject.Properties.Name -contains 'host_report'
        Assert-Integration `
            (-not $hasCancelledHostReport -or
                $null -eq $cancelResult.host_report) `
            'Queued cancellation incorrectly persisted a native host report.'
        Add-ScenarioEvidence -Name "queued-cancel-$iteration" -Data (
            [ordered]@{
                active_run_id = $activeId
                cancelled_run_id = $cancelId
                active_generation_preserved = $true
                cancellation_state = $cancelResult.state
            })

        $retainedId = "$prefix-retained"
        [void](Invoke-ManualBootstrap -Project $alphaRoot -RunId $retainedId)
        $retained = Wait-RunState -RunId $retainedId `
            -States @('passed', 'failed')
        Assert-Integration (-not $retained.snapshot.acknowledged) `
            'Manual terminal run was unexpectedly acknowledged.'
        $retainedFollowerId = "$prefix-retained-follower"
        $follower = Start-DwarfSpecRun -Project $betaRoot `
            -RunId $retainedFollowerId
        [void](Complete-CapturedProcess -Handle $follower)
        $followerResult = Read-RunResult -Path (
            Get-DefaultResultPath $betaRoot) -RunId $retainedFollowerId
        Assert-Integration ($followerResult.state -eq 'passed') `
            'Retained result blocked another project.'
        $stillRetained = Get-RunSnapshot -RunId $retainedId
        Assert-Integration (-not $stillRetained.snapshot.acknowledged) `
            'Another project changed retained-result ownership.'
        $retainedReloadResult = Invoke-BridgeScript -Script $controlScript `
            -Arguments @('compatible-reload', $retainedId, '0')
        $retainedReload = Get-CanonicalTransport -Result $retainedReloadResult
        Assert-Integration `
            (-not $retainedReload.snapshot.acknowledged) `
            'Compatible adapter reload changed retained-run acknowledgement.'
        $retainedLatest =
            $retainedReload.harness.registry.latest_terminal_results.
                ($retained.project_id)
        Assert-Integration ($retainedLatest -eq $retainedId) `
            'Compatible adapter reload changed the retained terminal index.'
        Invoke-Discard -Transport $stillRetained `
            -Reason 'multi-project retained-result proof complete'
        Add-ScenarioEvidence -Name "retained-result-$iteration" -Data (
            [ordered]@{
                retained_run_id = $retainedId
                follower_run_id = $retainedFollowerId
                follower_state = $followerResult.state
                retained_until_discard = $true
                compatible_reload_preserved = $true
            })

        $cleanupId = "$prefix-cleanup-quarantine"
        $cleanupPath = Get-ScenarioResultPath $commandRoot `
            "cleanup-quarantine-$iteration"
        [void](Invoke-DwarfSpecRun -Project $commandRoot -RunId $cleanupId `
            -TestGlob 'tests/live/cleanup_failure_spec.ds.lua' `
            -ResultPath $cleanupPath -ExpectedExitCode 6)
        $cleanupResult = Read-RunResult -Path $cleanupPath -RunId $cleanupId
        $quarantined = Get-RunSnapshot -RunId $cleanupId
        Assert-Integration $quarantined.harness.registry.quarantine.active `
            'Cleanup failure did not quarantine the executor.'
        Assert-Integration (-not $cleanupResult.host_report.cleanup_confirmed) `
            'Cleanup failure incorrectly confirmed cleanup.'
        $blockedId = "$prefix-quarantine-blocked"
        $blocked = Start-DwarfSpecRun -Project $betaRoot -RunId $blockedId
        $blockedSnapshot = Wait-RunState -RunId $blockedId -States @('queued')
        Assert-Integration `
            $blockedSnapshot.harness.registry.quarantine.active `
            'Queued follower did not observe executor quarantine.'
        $recovered = Invoke-ExecutorRecovery -Transport $quarantined `
            -Reason 'integration verified drained cleanup resources'
        Assert-Integration (-not $recovered.scheduler.quarantine.active) `
            'Explicit clean-state recovery did not clear quarantine.'
        [void](Complete-CapturedProcess -Handle $blocked)
        $blockedResult = Read-RunResult -Path (
            Get-DefaultResultPath $betaRoot) -RunId $blockedId
        Assert-Integration ($blockedResult.state -eq 'passed') `
            'Recovered executor did not activate queued follower.'
        Add-ScenarioEvidence -Name "quarantine-$iteration" -Data (
            [ordered]@{
                failed_run_id = $cleanupId
                blocked_run_id = $blockedId
                quarantine_observed = $true
                recovery_verified = $true
                follower_state = $blockedResult.state
            })

        $leaseActiveId = "$prefix-queue-lease-active"
        $leaseActive = Start-DwarfSpecRun -Project $alphaRoot `
            -RunId $leaseActiveId
        [void](Wait-RunState -RunId $leaseActiveId `
            -States @('starting', 'running'))
        $queueLeaseId = "$prefix-queue-lease-expired"
        [void](Invoke-ManualBootstrap -Project $gammaRoot `
            -RunId $queueLeaseId -LeaseMilliseconds 100)
        $queueExpired = Wait-RunState -RunId $queueLeaseId `
            -States @('cancelled')
        Assert-Integration $queueExpired.snapshot.queue_lease.expired `
            'Queue lease expiry did not mark the queue lease expired.'
        $queueActivated =
            $queueExpired.snapshot.PSObject.Properties.Name -contains
                'activated_at_ms'
        Assert-Integration (-not $queueActivated) `
            'Queue lease expiry entered native execution.'
        [void](Complete-CapturedProcess -Handle $leaseActive)
        Invoke-Discard -Transport $queueExpired `
            -Reason 'queue lease expiry evidence recorded'

        $executionLeaseId = "$prefix-execution-lease-expired"
        [void](Invoke-ManualBootstrap -Project $alphaRoot `
            -RunId $executionLeaseId -LeaseMilliseconds 100)
        $executionExpired = Wait-RunState -RunId $executionLeaseId `
            -States @('aborted')
        Assert-Integration $executionExpired.snapshot.execution_lease.expired `
            'Execution lease expiry did not mark the execution lease expired.'
        Assert-Integration $executionExpired.snapshot.cleanup_confirmed `
            'Execution lease expiry did not confirm native cleanup.'
        Invoke-Discard -Transport $executionExpired `
            -Reason 'execution lease expiry evidence recorded'
        Add-ScenarioEvidence -Name "lease-expiry-$iteration" -Data (
            [ordered]@{
                queued = [ordered]@{
                    run_id = $queueLeaseId
                    state = $queueExpired.snapshot.state
                    activated = $false
                }
                execution = [ordered]@{
                    run_id = $executionLeaseId
                    state = $executionExpired.snapshot.state
                    cleanup_confirmed =
                        $executionExpired.snapshot.cleanup_confirmed
                }
            })

        $timeoutId = "$prefix-timeout"
        $timeoutPath = Get-ScenarioResultPath $commandRoot "timeout-$iteration"
        [void](Invoke-DwarfSpecRun -Project $commandRoot -RunId $timeoutId `
            -TestGlob 'tests/live/timeout_spec.ds.lua' `
            -ResultPath $timeoutPath -ExpectedExitCode 7 `
            -TimeoutSeconds 0.2)
        $timeoutResult = Read-RunResult -Path $timeoutPath -RunId $timeoutId
        Assert-Integration ($timeoutResult.state -eq 'timeout') `
            'Execution timeout classification changed.'
        Assert-Integration $timeoutResult.host_report.cleanup_confirmed `
            'Execution timeout did not confirm cleanup.'

        $interruptId = "$prefix-interruption"
        $interruptPath = Get-ScenarioResultPath $commandRoot `
            "interruption-$iteration"
        $knownRunIds.Add($interruptId)
        [void](Invoke-CapturedProcess -FilePath 'lua' -Arguments @(
            $scenarioRunner, 'interrupt', $projectRoot, $commandRoot,
            $interruptPath, $interruptId
        ) -ExpectedExitCodes @(8))
        $interruptResult = Read-RunResult -Path $interruptPath `
            -RunId $interruptId
        Assert-Integration ($interruptResult.state -eq 'interrupted') `
            'Interruption classification changed.'
        Assert-Integration $interruptResult.host_report.cleanup_confirmed `
            'Interruption did not confirm cleanup.'

        $explicitId = "$prefix-explicit-abort"
        $explicitPath = Get-ScenarioResultPath $commandRoot `
            "explicit-abort-$iteration"
        $explicit = Start-DwarfSpecRun -Project $commandRoot `
            -RunId $explicitId -TestGlob 'tests/live/timeout_spec.ds.lua' `
            -ResultPath $explicitPath
        [void](Wait-RunState -RunId $explicitId -States @('running'))
        [void](Invoke-CapturedProcess -FilePath 'lua' -Arguments @(
            $launcher, 'abort', $explicitId, "--project-root=$commandRoot"
        ))
        [void](Complete-CapturedProcess -Handle $explicit `
            -ExpectedExitCodes @(8))
        $explicitResult = Read-RunResult -Path $explicitPath -RunId $explicitId
        Assert-Integration ($explicitResult.state -eq 'aborted') `
            'Explicit abort classification changed.'
        Assert-Integration $explicitResult.host_report.cleanup_confirmed `
            'Explicit abort did not confirm cleanup.'

        $assertionId = "$prefix-assertion"
        $assertionPath = Get-ScenarioResultPath $commandRoot `
            "assertion-$iteration"
        [void](Invoke-DwarfSpecRun -Project $commandRoot -RunId $assertionId `
            -TestGlob 'tests/live/failure_spec.ds.lua' `
            -ResultPath $assertionPath -ExpectedExitCode 6)
        $assertionResult = Read-RunResult -Path $assertionPath `
            -RunId $assertionId
        Assert-Integration ($assertionResult.state -eq 'failed') `
            'Assertion failure classification changed.'
        Assert-Integration $assertionResult.host_report.cleanup_confirmed `
            'Assertion failure did not confirm cleanup.'
        $assertionMessages = @($assertionResult.events |
            Where-Object { $_.type -eq 'problem.recorded' } |
            ForEach-Object { $_.payload.message }) -join "`n"
        Assert-Integration `
            ($assertionMessages -match 'deliberate failure') `
            'Assertion failure detail was not retained.'

        $combinedId = "$prefix-combined"
        $combinedPath = Get-ScenarioResultPath $commandRoot `
            "combined-$iteration"
        [void](Invoke-DwarfSpecRun -Project $commandRoot -RunId $combinedId `
            -TestGlob 'tests/live/combined_failure_spec.ds.lua' `
            -ResultPath $combinedPath -ExpectedExitCode 6)
        $combinedResult = Read-RunResult -Path $combinedPath -RunId $combinedId
        $combinedMessages = @($combinedResult.events |
            Where-Object { $_.type -eq 'problem.recorded' } |
            ForEach-Object { $_.payload.message }) -join "`n"
        Assert-Integration `
            ($combinedMessages -match 'originating assertion detail') `
            'Combined failure lost the originating assertion.'
        Assert-Integration `
            ($combinedMessages -match 'deliberate cleanup error detail') `
            'Combined failure lost the cleanup error.'
        $combinedTransport = Get-RunSnapshot -RunId $combinedId
        Assert-Integration `
            $combinedTransport.harness.registry.quarantine.active `
            'Combined cleanup failure did not quarantine the executor.'
        [void](Invoke-ExecutorRecovery -Transport $combinedTransport `
            -Reason 'combined failure cleanup resources verified')

        $transportId = "$prefix-transport"
        $transportPath = Get-ScenarioResultPath $commandRoot `
            "transport-$iteration"
        $knownRunIds.Add($transportId)
        [void](Invoke-CapturedProcess -FilePath 'lua' -Arguments @(
            $scenarioRunner, 'transport', $projectRoot, $commandRoot,
            $transportPath, $transportId
        ) -ExpectedExitCodes @(5))
        $transportResult = Read-RunResult -Path $transportPath `
            -RunId $transportId
        Assert-Integration ($transportResult.state -eq 'host_error') `
            'Malformed transport classification changed.'
        Assert-Integration `
            ($transportResult.error.message -match
                'did not contain a DWARFSPEC_JSON report') `
            'Malformed transport did not remain the primary failure.'
        Assert-Integration $transportResult.host_report.cleanup_confirmed `
            'Malformed transport recovery did not confirm cleanup.'
        Add-ScenarioEvidence -Name "failure-classifications-$iteration" `
            -Data ([ordered]@{
                timeout = $timeoutResult.state
                interruption = $interruptResult.state
                explicit_abort = $explicitResult.state
                assertion = $assertionResult.state
                combined_assertion_retained = $true
                combined_cleanup_retained = $true
                transport = $transportResult.state
            })

        $isolationId = "$prefix-isolation-source"
        $isolationPath = Get-ScenarioResultPath $projectRoot `
            "isolation-source-$iteration"
        [void](Invoke-DwarfSpecRun -Project $projectRoot -RunId $isolationId `
            -TestGlob 'tests/automation/interaction_live_spec.lua' `
            -ResultPath $isolationPath -ExpectedExitCode 0)
        $isolationTransport = Get-RunSnapshot -RunId $isolationId
        Assert-CleanRun -Transport $isolationTransport
        Assert-Integration `
            $isolationTransport.snapshot.mount_cleanup_verified `
            'Isolation source did not verify mount cleanup.'
        $isolationFollowerId = "$prefix-isolation-follower"
        $isolationFollower = Start-DwarfSpecRun -Project $gammaRoot `
            -RunId $isolationFollowerId
        [void](Complete-CapturedProcess -Handle $isolationFollower)
        $isolationFollowerResult = Read-RunResult -Path (
            Get-DefaultResultPath $gammaRoot) -RunId $isolationFollowerId
        Assert-Integration ($isolationFollowerResult.state -eq 'passed') `
            'Consecutive project isolation follower failed.'
        Assert-CleanRun -Transport (
            Get-RunSnapshot -RunId $isolationFollowerId)
        Add-ScenarioEvidence -Name "module-isolation-$iteration" -Data (
            [ordered]@{
                source_run_id = $isolationId
                follower_run_id = $isolationFollowerId
                mount_cleanup_verified =
                    $isolationTransport.snapshot.mount_cleanup_verified
                project_module_environment_restored = $true
                screens_subjects_pointer_waits_timers_cleared = $true
            })
    }
} catch {
    $message = $_.Exception.ToString()
    if ($message.Length -gt 4096) { $message = $message.Substring(0, 4096) }
    $evidence.failure = [ordered]@{
        message = $message
        captured_at = [DateTime]::UtcNow.ToString('o')
    }
    throw
} finally {
    if ($null -ne $evidence.failure) { Repair-IntegrationState }
    $evidence['finished_at'] = [DateTime]::UtcNow.ToString('o')
    $evidence['passed'] = $null -eq $evidence.failure
    $evidenceDirectory = Split-Path -Parent $evidencePath
    [void](New-Item -ItemType Directory -Force -Path $evidenceDirectory)
    $temporaryPath = "$evidencePath.tmp"
    $evidence | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporaryPath -Destination $evidencePath -Force
    [Environment]::SetEnvironmentVariable(
        'DFHACK_ROOT', $oldDFHackRoot, 'Process')
    [Environment]::SetEnvironmentVariable(
        'DFHACK_RUNNER', $oldDFHackRunner, 'Process')
}

Write-Host "Multi-project integration passed $Iterations repeated iteration(s)."
Write-Host "Evidence: $evidencePath"
