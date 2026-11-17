# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

<#
.SYNOPSIS
Compares two built module directories in isolated PowerShell processes.
.DESCRIPTION
Generates unrelated managed DLLs in a temporary directory, copies each module,
and measures discovery separately from a complete alias-analysis invocation.
Outputs one object per process. Preparation and import are outside the timings.
The crowded layout is synthetic, not an ImmyBot/editor end-to-end benchmark.
#>
[CmdletBinding(DefaultParameterSetName = 'Compare')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string] $BeforeModulePath,
    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string] $AfterModulePath,
    [Parameter(ParameterSetName = 'Compare')]
    [ValidateRange(1, 100)]
    [int] $Runs = 5,
    [Parameter(ParameterSetName = 'Compare')]
    [ValidateRange(1, 1000)]
    [int] $AdjacentAssemblyCount = 410,
    [Parameter(ParameterSetName = 'Compare')]
    [ValidateRange(1, 1000)]
    [int] $TypesPerAssembly = 100,
    [ValidateRange(1, 10000)]
    [int] $Iterations = 30,
    [Parameter(Mandatory, ParameterSetName = 'Worker')]
    [string] $ModulePath,
    [Parameter(Mandatory, ParameterSetName = 'Worker')]
    [ValidateSet('Discovery', 'Analysis')]
    [string] $Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSCmdlet.ParameterSetName -eq 'Worker') {
    Import-Module (Join-Path $ModulePath 'PSScriptAnalyzer.psd1')
    $operation = if ($Mode -eq 'Discovery') {
        { Get-ScriptAnalyzerRule }
    } else {
        { Invoke-ScriptAnalyzer -ScriptDefinition 'gci' -IncludeRule PSAvoidUsingCmdletAliases }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $memoryBefore = [Environment]::WorkingSet
    $assembliesBefore = [AppDomain]::CurrentDomain.GetAssemblies().Count
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $first = @(& $operation)
    $watch.Stop()
    $coldMs = $watch.Elapsed.TotalMilliseconds
    $memoryDelta = [Environment]::WorkingSet - $memoryBefore
    $assembliesDelta = [AppDomain]::CurrentDomain.GetAssemblies().Count - $assembliesBefore
    $ruleNames = @($first.RuleName | Sort-Object)
    if ($Mode -eq 'Discovery' -and $ruleNames.Count -ne 69) {
        throw "Expected 69 built-in rules, got $($ruleNames.Count)"
    }
    if ($Mode -eq 'Analysis' -and ($ruleNames.Count -ne 1 -or $ruleNames[0] -ne 'PSAvoidUsingCmdletAliases')) {
        throw 'Alias diagnostic changed'
    }
    # Warm JIT and rule dependencies before steady-state samples.
    1..5 | ForEach-Object { $null = & $operation }
    $samples = [Collections.Generic.List[double]]::new()
    $allocatedBefore = [GC]::GetTotalAllocatedBytes($true)
    for ($i = 0; $i -lt $Iterations; $i++) {
        $watch.Restart()
        $null = & $operation
        $watch.Stop()
        $samples.Add($watch.Elapsed.TotalMilliseconds)
    }
    $allocated = [GC]::GetTotalAllocatedBytes($true) - $allocatedBefore
    $ordered = @($samples | Sort-Object)
    # Verbose capture is deliberately outside timed/allocation samples.
    $trace = if ($Mode -eq 'Discovery') {
        @(Get-ScriptAnalyzerRule -Verbose 4>&1)
    } else {
        @(Invoke-ScriptAnalyzer -ScriptDefinition 'gci' -IncludeRule PSAvoidUsingCmdletAliases -Verbose 4>&1)
    }
    [pscustomobject]@{
        Mode = $Mode
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Runtime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        ColdMs = $coldMs
        WarmMedianMs = $ordered[[int][Math]::Floor($Iterations / 2)]
        WarmP95Ms = $ordered[[int][Math]::Ceiling($Iterations * 0.95) - 1]
        AllocatedBytesPerCall = $allocated / $Iterations
        ColdWorkingSetDeltaBytes = $memoryDelta
        ColdLoadedAssemblies = $assembliesDelta
        AdjacentLoadedAssemblies = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
            -not $_.IsDynamic -and [IO.Path]::GetFileName($_.Location) -like 'DiscoveryFixture*.dll'
        }).Count
        AssemblyInspectionsPerCall = @($trace | Where-Object {
            $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like 'Loading Assembly:*'
        }).Count
        RuleNames = $ruleNames
        WarmSamplesMs = @($samples)
    } | ConvertTo-Json -Depth 4 -Compress
    return
}

$before = (Resolve-Path $BeforeModulePath).Path
$after = (Resolve-Path $AfterModulePath).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('PssaDiscovery-' + [Guid]::NewGuid())
$powerShell = (Get-Process -Id $PID).Path
try {
    $fixtures = New-Item (Join-Path $scratch 'fixtures') -ItemType Directory -Force
    for ($i = 0; $i -lt $AdjacentAssemblyCount; $i++) {
        $classes = (0..($TypesPerAssembly - 1) | ForEach-Object { "public class Type$_ {}" }) -join "`n"
        Add-Type -TypeDefinition "namespace DiscoveryFixture$i { $classes }" `
            -OutputAssembly (Join-Path $fixtures.FullName "DiscoveryFixture$i.dll")
    }
    foreach ($count in @(0, $AdjacentAssemblyCount)) {
        foreach ($variant in @('Before', 'After')) {
            $source = if ($variant -eq 'Before') { $before } else { $after }
            $destination = Join-Path $scratch "$variant-$count"
            Copy-Item $source $destination -Recurse
            if ($count -gt 0) {
                Copy-Item "$($fixtures.FullName)/*.dll" (Join-Path $destination 'PSv7')
            }
        }
        for ($run = 1; $run -le $Runs; $run++) {
            # Alternate build order to reduce systematic warm-cache/time bias.
            $variants = if ($run % 2) { @('Before', 'After') } else { @('After', 'Before') }
            foreach ($modeName in @('Discovery', 'Analysis')) {
                foreach ($variant in $variants) {
                    $output = & $powerShell -NoLogo -NoProfile -File $PSCommandPath `
                        -ModulePath (Join-Path $scratch "$variant-$count") `
                        -Mode $modeName -Iterations $Iterations
                    if ($LASTEXITCODE -ne 0) { throw "Benchmark child failed: $variant/$count/$modeName" }
                    $result = $output | ConvertFrom-Json
                    $result | Add-Member -NotePropertyMembers @{
                        Variant = $variant; Run = $run; AdjacentAssemblies = $count
                        TypesPerAssembly = $TypesPerAssembly; Iterations = $Iterations
                    }
                    $result
                }
            }
        }
    }
} finally {
    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
}
