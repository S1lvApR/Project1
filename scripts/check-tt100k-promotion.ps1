param(
    [string]$Baseline = "training\runs\tt100k_baseline_corrected\metrics.json",
    [Parameter(Mandatory = $true)]
    [string]$Candidate,
    [string]$Output = "training\runs\tt100k_promotion.json"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$python = Join-Path $projectRoot "backend\.venv\Scripts\python.exe"

& $python -X utf8 (Join-Path $projectRoot "backend\tools\check_yolo_promotion.py") `
    --baseline (Join-Path $projectRoot $Baseline) `
    --candidate (Join-Path $projectRoot $Candidate) `
    --output (Join-Path $projectRoot $Output)
if ($LASTEXITCODE -ne 0) {
    throw "TT100K candidate did not pass the promotion gate"
}
