[CmdletBinding()]
param(
    [string] $OutputDir = 'dist'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rockspecPath = Join-Path $projectRoot 'dwarfspec.rockspec'
if (-not (Test-Path -LiteralPath $rockspecPath -PathType Leaf)) {
    throw "Missing release rockspec: $rockspecPath"
}
if (-not (Get-Command luarocks -ErrorAction SilentlyContinue)) {
    throw 'LuaRocks was not found on PATH.'
}

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
$versionedRockspecName = "$packageName-$packageVersion.rockspec"
$artifactName = "$packageName-$packageVersion.all.rock"
$stagedArtifact = Join-Path $projectRoot $artifactName
$outputCandidate = if ([IO.Path]::IsPathFullyQualified($OutputDir)) {
    $OutputDir
} else {
    Join-Path $projectRoot $OutputDir
}
$outputPath = [IO.Path]::GetFullPath($outputCandidate)
$publishedArtifact = Join-Path $outputPath $artifactName
$scratchRoot = Join-Path $projectRoot '.tmp-luarocks'
$tempRoot = Join-Path $scratchRoot "publish-$([guid]::NewGuid())"
$configPath = Join-Path $tempRoot 'config.lua'
$buildRockspecPath = Join-Path $tempRoot $versionedRockspecName

$oldConfig = [Environment]::GetEnvironmentVariable(
    'LUAROCKS_CONFIG', 'Process')
$oldTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
$oldTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
[IO.File]::WriteAllText($configPath, "arch = 'all'`n")
[IO.File]::WriteAllText($buildRockspecPath, $rockspec)

try {
    Set-Item -LiteralPath Env:LUAROCKS_CONFIG -Value $configPath
    Set-Item -LiteralPath Env:TEMP -Value $scratchRoot
    Set-Item -LiteralPath Env:TMP -Value $scratchRoot

    & luarocks lint $buildRockspecPath
    if ($LASTEXITCODE -ne 0) {
        throw 'LuaRocks rejected the release rockspec.'
    }

    if (Test-Path -LiteralPath $stagedArtifact -PathType Leaf) {
        Remove-Item -LiteralPath $stagedArtifact -Force
    }
    Push-Location $projectRoot
    try {
        & luarocks make $buildRockspecPath `
            --pack-binary-rock --deps-mode=none
        if ($LASTEXITCODE -ne 0) {
            throw 'LuaRocks failed to build the release rock.'
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $stagedArtifact -PathType Leaf)) {
        throw "LuaRocks did not produce the expected artifact: $artifactName"
    }
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    Move-Item -LiteralPath $stagedArtifact `
        -Destination $publishedArtifact -Force
    Write-Host "Created $publishedArtifact"
} finally {
    if ($null -eq $oldConfig) {
        Remove-Item -LiteralPath Env:LUAROCKS_CONFIG `
            -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath Env:LUAROCKS_CONFIG -Value $oldConfig
    }
    if ($null -eq $oldTemp) {
        Remove-Item -LiteralPath Env:TEMP -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath Env:TEMP -Value $oldTemp
    }
    if ($null -eq $oldTmp) {
        Remove-Item -LiteralPath Env:TMP -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath Env:TMP -Value $oldTmp
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
