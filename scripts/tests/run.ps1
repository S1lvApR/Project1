$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$suites = @(
    [pscustomobject]@{
        Path = (Join-Path $PSScriptRoot "ProjectEnvironment.Tests.ps1")
        Invoker = "Invoke-ProjectEnvironmentTests"
    },
    [pscustomobject]@{
        Path = (Join-Path $PSScriptRoot "BootstrapScripts.Tests.ps1")
        Invoker = "Invoke-BootstrapScriptTests"
    }
)

$allResults = @()
$passedCount = 0
$failedCount = 0

foreach ($suite in $suites) {
    try {
        . $suite.Path
        $summary = & $suite.Invoker
        $allResults += $summary.Results
        $passedCount += $summary.Passed
        $failedCount += $summary.Failed
    } catch {
        $allResults += [pscustomobject]@{
            Name = "Suite initialization: $($suite.Path)"
            Passed = $false
            Error = $_.Exception.Message
        }
        $failedCount++
    }
}

foreach ($result in $allResults) {
    if ($result.Passed) {
        Write-Host "PASS $($result.Name)"
    } else {
        Write-Host "FAIL $($result.Name)"
        Write-Host "  $($result.Error)"
    }
}

Write-Host ""
Write-Host "Passed: $passedCount"
Write-Host "Failed: $failedCount"

if ($failedCount -gt 0) {
    exit 1
}

exit 0
