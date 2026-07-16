param(
    [string]$Model = "training\runs\gtsrb_yolo11n_cls_gpu_final\weights\best.pt",
    [string]$Output = "training\runs\gtsrb_yolo11n_cls_gpu_final\test_metrics",
    [int]$ImageSize = 128,
    [int]$Batch = 256,
    [string]$Device = "0"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$python = Join-Path $projectRoot "backend\.venv\Scripts\python.exe"
$env:YOLO_CONFIG_DIR = Join-Path $projectRoot ".venv\ultralytics"
$env:MPLCONFIGDIR = Join-Path $projectRoot ".venv\matplotlib"

& $python -X utf8 (Join-Path $projectRoot "backend\tools\evaluate_gtsrb.py") `
    --model (Join-Path $projectRoot $Model) `
    --test-dir (Join-Path $projectRoot "Test") `
    --ground-truth (Join-Path $projectRoot "Test\GT-final_test.csv") `
    --output (Join-Path $projectRoot $Output) `
    --device $Device `
    --imgsz $ImageSize `
    --batch $Batch
if ($LASTEXITCODE -ne 0) {
    throw "GTSRB evaluation failed with exit code $LASTEXITCODE"
}
