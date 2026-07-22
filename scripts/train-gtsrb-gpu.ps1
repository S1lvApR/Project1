param(
    [int]$Epochs = 50,
    [int]$ImageSize = 128,
    [int]$Batch = 128,
    [string]$Device = "0",
    [string]$RunName = "gtsrb_yolo11n_cls_gpu_final",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$python = Join-Path $projectRoot "backend\.venv\Scripts\python.exe"
$data = Join-Path $projectRoot "training\datasets\gtsrb_cls_final"
$model = Join-Path $projectRoot "backend\yolo11n-cls.pt"
$runs = Join-Path $projectRoot "training\runs"
$env:YOLO_CONFIG_DIR = Join-Path $projectRoot ".venv\ultralytics"
$env:MPLCONFIGDIR = Join-Path $projectRoot ".venv\matplotlib"
New-Item -ItemType Directory -Force -Path $env:YOLO_CONFIG_DIR, $env:MPLCONFIGDIR | Out-Null

$arguments = @(
    "-X", "utf8", (Join-Path $projectRoot "backend\tools\train_gtsrb.py"),
    "--data", $data,
    "--model", $model,
    "--epochs", $Epochs,
    "--imgsz", $ImageSize,
    "--batch", $Batch,
    "--device", $Device,
    "--workers", "2",
    "--project", $runs,
    "--name", $RunName,
    "--patience", "12",
    "--exist-ok"
)
if ($DryRun) {
    $arguments += "--dry-run"
}
& $python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "GTSRB training failed with exit code $LASTEXITCODE"
}
