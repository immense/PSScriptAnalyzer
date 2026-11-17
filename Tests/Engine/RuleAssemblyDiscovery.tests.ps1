# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

Describe 'PowerShell Core built-in rule discovery' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
    BeforeAll {
        $moduleRoot = (Get-Module PSScriptAnalyzer).ModuleBase
        $powerShell = (Get-Process -Id $PID).Path
        $childScript = Join-Path $TestDrive 'Test-Discovery.ps1'
        @'
param($ModulePath, $CustomRulePath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath
$rules = @(Get-ScriptAnalyzerRule)
$diagnostics = @(Invoke-ScriptAnalyzer -ScriptDefinition 'gci' -IncludeRule PSAvoidUsingCmdletAliases)
$custom = @(Invoke-ScriptAnalyzer -ScriptDefinition 'gci' -Settings @{
    CustomRulePath = $CustomRulePath
    IncludeDefaultRules = $true
    IncludeRules = @('PSAvoidUsingCmdletAliases', 'Measure-RequiresRunAsAdministrator')
})
$customOnly = @(Invoke-ScriptAnalyzer -ScriptDefinition 'gci' -CustomRulePath $CustomRulePath)
$formatted = Invoke-Formatter -ScriptDefinition 'gci'
[pscustomobject]@{
    Rules = @($rules.RuleName)
    Diagnostics = @($diagnostics.RuleName)
    Custom = @($custom.RuleName)
    CustomOnly = @($customOnly.RuleName)
    Formatted = $formatted
    UnrelatedLoaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        -not $_.IsDynamic -and [IO.Path]::GetFileName($_.Location) -eq 'Unrelated.Host.dll'
    }).Count
} | ConvertTo-Json -Compress
'@ | Set-Content $childScript

        # Compile outside the child: loading it in the test runner must not hide
        # whether discovery loads it in the fresh process.
        $managedDll = Join-Path $TestDrive 'Unrelated.Host.dll'
        Add-Type -TypeDefinition 'public class UnrelatedDiscoveryFixture {}' -OutputAssembly $managedDll
        $dependencyDll = Join-Path $TestDrive 'MissingDependency.dll'
        Add-Type -TypeDefinition 'public class MissingDiscoveryDependency {}' -OutputAssembly $dependencyDll
        $missingDependencyDll = Join-Path $TestDrive 'MissingDependency.Host.dll'
        Add-Type -TypeDefinition 'public class DerivedDiscoveryFixture : MissingDiscoveryDependency {}' `
            -ReferencedAssemblies $dependencyDll -OutputAssembly $missingDependencyDll
    }

    It 'ignores an unrelated <Kind> DLL and preserves built-in and explicit custom rules' -TestCases @(
        @{ Kind = 'invalid' }
        @{ Kind = 'managed' }
        @{ Kind = 'missing dependency' }
    ) {
        param($Kind)
        $copy = Join-Path $TestDrive $Kind
        Copy-Item $moduleRoot $copy -Recurse
        $adjacentDll = Join-Path $copy 'PSv7/Unrelated.Host.dll'
        if ($Kind -eq 'invalid') {
            Set-Content $adjacentDll 'Not a managed assembly'
        } elseif ($Kind -eq 'missing dependency') {
            Copy-Item $missingDependencyDll $adjacentDll
        } else {
            Copy-Item $managedDll $adjacentDll
        }

        $output = & $powerShell -NoLogo -NoProfile -File $childScript `
            -ModulePath (Join-Path $copy 'PSScriptAnalyzer.psd1') `
            -CustomRulePath "$PSScriptRoot/samplerule/samplerule.psm1" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $result = $output | ConvertFrom-Json
        $result.Rules.Count | Should -Be 69
        $result.Rules | Should -Contain 'PSAvoidUsingCmdletAliases'
        $result.Rules | Should -Contain 'PSDSCUseIdenticalParametersForDSC'
        $result.Diagnostics | Should -Be @('PSAvoidUsingCmdletAliases')
        $result.Custom | Should -Contain 'PSAvoidUsingCmdletAliases'
        $result.Custom | Should -Contain 'samplerule\Measure-RequiresRunAsAdministrator'
        $result.CustomOnly | Should -Be @('samplerule\Measure-RequiresRunAsAdministrator')
        $result.Formatted | Should -Be 'gci'
        $result.UnrelatedLoaded | Should -Be 0
    }
}
