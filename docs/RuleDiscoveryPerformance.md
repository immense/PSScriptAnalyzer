# Built-in rule discovery performance

## Why this changed

[ImmyBot PR 11257](https://github.com/immense/immybot/pull/11257) exposed a
PowerShell Core discovery problem: PSScriptAnalyzer enumerated every `*.dll`
beside its engine, loaded each assembly, and walked its exported types four times
per invocation (loggers, script rules, token rules, DSC rules). In a host's output
directory, unrelated DLLs made analysis expensive and missing dependencies could
abort it entirely. Rule-name filters run too late to prevent this work.

The engine now discovers loggers in its own assembly and rules in the known
`Microsoft.Windows.PowerShell.ScriptAnalyzer.BuiltinRules` assembly. It creates
fresh rule instances each time, preserving per-invocation configuration. No cache,
environment variable, or glob setting is required. Explicit PowerShell custom
rules still use `CustomRulePath`, including its wildcard/recursion support.

Compatibility: adjacency alone no longer registers third-party compiled rules or
loggers on PowerShell Core. This change does not add Core support for compiled
custom-rule paths. The legacy full-framework MEF implementation is unchanged.

## Measurements

Measured November 17, 2026, on macOS 27.2 arm64, PowerShell 7.6.1 / .NET 10.0.7.
Both builds used SDK 10.0.400, `PSV7Release`, `net6`, and identical dependencies.
Baseline: `immybot-latest` commit `43c1fa343c2dbfc8ba9ec3b1641ab141087954d2`.
The fixed build differs only in `Engine/ScriptAnalyzer.cs`.

The normal module directory contains six managed DLLs. The crowded fixture adds
410 unrelated managed DLLs, each exporting 100 empty classes. This is a synthetic
scaling experiment, not the actual ImmyBot application directory.

Each build/layout/operation used five fresh processes. Each process records its
first call, makes five warm-up calls, then measures 30 calls. Build order alternates
between runs. Module import and fixture generation are outside the timings.
Numbers below are medians across the five processes; warm values are medians of
each process's 30 calls. Verbose inspection counts are collected separately.

| Operation / layout | Before warm (ms) | After warm (ms) | Before first call (ms) | After first call (ms) |
| --- | ---: | ---: | ---: | ---: |
| Discovery, no extra DLLs | 0.479 | 0.276 | 45.848 | 44.336 |
| Analysis, no extra DLLs | 3.080 | 1.112 | 56.245 | 63.492 |
| Discovery, 410 extra DLLs | 15.685 | 0.252 | 118.493 | 25.831 |
| Analysis, 410 extra DLLs | 15.770 | 0.363 | 144.083 | 34.432 |

Discovery is `Get-ScriptAnalyzerRule`: initialization and rule listing, without
script analysis. Analysis is a complete `Invoke-ScriptAnalyzer -ScriptDefinition
'gci' -IncludeRule PSAvoidUsingCmdletAliases` call, including initialization. This
small script and single rule isolate the discovery penalty; they do not represent
the cost of running every rule on a large script.

With 410 extra DLLs, warm discovery was 62.2x faster and the full alias-analysis
call was 43.4x faster. Individual process warm medians ranged from 12.341–15.983 ms
before versus 0.251–0.288 ms after for discovery, and 14.702–29.902 ms before versus
0.339–0.482 ms after for analysis.

| Crowded-layout metric | Before | After |
| --- | ---: | ---: |
| Assembly type inspections per call | 1,664 | 4 |
| Unrelated fixture assemblies loaded | 410 | 0 |
| Discovery allocated bytes per warm call | 3,937,252 | 190,920 |
| Analysis allocated bytes per warm call | 3,929,312 | 182,481 |
| Discovery first-call working-set increase | 28.59 MiB | 2.52 MiB |
| Analysis first-call working-set increase | 28.11 MiB | 2.34 MiB |

All 40 processes returned identical results within each operation: the same 69
built-in rule names, or the same single alias diagnostic. The deterministic
assembly counts corroborate the timing result. Working set and timings are noisy
on a shared machine; the clean-layout cold analysis did not improve. These numbers
are not an editor keystroke latency claim, do not measure PSES's debounce, and do
not establish how much of ImmyBot's historical slowness this accounts for.

## Reproduce

Build separate durable checkouts of the baseline commit and the PR head with the
same SDK and dependencies. From a directory using the selected SDK (the checkout's
`global.json` pins 6.0.403), run for each checkout:

```powershell
dotnet build "$source/Rules/Rules.csproj" -c PSV7Release -f net6 -m:1 `
    -p:BuildInParallel=false -p:ImportDirectoryBuildProps=false `
    -p:ImportDirectoryBuildTargets=false -p:ManagePackageVersionsCentrally=false
if ($LASTEXITCODE) { throw 'Build failed' }
```

The last three properties isolate these independent checkouts from a containing
repository's MSBuild configuration. They were identical in both measured builds.
On shared ImmyBot development machines, also apply the machine's load check and
build lock.

Prepare a module directory for each build, with `PSScriptAnalyzer.psd1`,
`PSScriptAnalyzer.psm1`, `ScriptAnalyzer.types.ps1xml`, and
`ScriptAnalyzer.format.ps1xml` from `Engine`; `Engine/Settings` as `Settings`; and
`PSCompatibilityCollector/profiles` as `compatibility_profiles`. Put these six
DLLs from `Rules/bin/PSV7Release/net6` in its `PSv7` subdirectory:

- `Microsoft.Windows.PowerShell.ScriptAnalyzer.dll`
- `Microsoft.Windows.PowerShell.ScriptAnalyzer.BuiltinRules.dll`
- `Microsoft.PowerShell.CrossCompatibility.dll`
- `Pluralize.NET.dll`
- `Microsoft.VisualStudio.Threading.dll`
- `Microsoft.VisualStudio.Validation.dll`

The threading dependencies are necessary for this fork even though the old
`build.ps1` copy list omits them. Use the same non-analyzer assets for both builds.
The recorded run used these assets from ImmyBot's installed private 1.21.0 package
and replaced the six DLLs with the respective source build outputs.

Run the harness from the PR checkout in PowerShell Core:

```powershell
$results = ./tools/Measure-RuleDiscovery.ps1 `
    -BeforeModulePath $beforeModule -AfterModulePath $afterModule `
    -Runs 5 -Iterations 30 -AdjacentAssemblyCount 410 -TypesPerAssembly 100
$results | ConvertTo-Json -Depth 5 | Set-Content $resultsPath
```

Use temporary directories for modules/results. The harness creates and removes
its own fixture directory. It emits raw samples, rule names, assembly inspection
and load counts, allocated bytes, working-set deltas, and runtime version. Each
child process fails if the expected built-in rule count or alias diagnostic changes.

## Regression validation

`Tests/Engine/RuleAssemblyDiscovery.tests.ps1` copies the real module into an
isolated directory and invokes a fresh PowerShell process for each of three cases:
an invalid DLL, an unrelated managed DLL, and a managed DLL with a missing base-type
dependency. All three fail on the baseline and pass on the fixed build. Each case
also checks built-in rule listing/diagnostics, formatting, a custom PowerShell rule
selected through settings with built-ins, and custom-only analysis.

The final focused discovery/custom-rule/settings/formatter suite passed 138 tests
with 2 skips, including all three new regression cases. The broader engine/rule
suite passed 1,276 tests with 148 skips and
10 failures, all reproduced on the unchanged baseline in the same environment:
2 attempts to write outside the sandbox, 3 help-description checks for the newer
`ProgressAction` common parameter, and 5 existing compatibility-profile assertions.
Both source builds succeeded with the same four existing warnings.

This PR does not publish a new package or change ImmyBot's package reference. Those
steps and verification in an actual editor process remain integration work.
