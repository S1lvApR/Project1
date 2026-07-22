param(
    [int]$Epochs = 100,
    [int]$ImageSize = 1280,
    [int]$Batch = 8,
    [string]$Device = "0",
    [string]$Optimizer = "SGD",
    [double]$LearningRate = 0.01,
    [double]$Momentum = 0.937,
    [double]$Fraction = 1.0,
    [string]$RunName = "tt100k_yolo11n_gpu_corrected_sgd_b8",
    [string]$DataYaml = "training\datasets\tt100k_corrected_45\data.yaml",
    [switch]$Resume,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$backendRoot = Join-Path $projectRoot "backend"
$python = Join-Path $backendRoot ".venv\Scripts\python.exe"
$dataYaml = Join-Path $projectRoot $DataYaml
$dataYaml = (Resolve-Path -LiteralPath $dataYaml -ErrorAction Stop).Path
$runsDir = Join-Path $projectRoot "training\runs"
$model = "yolo11n.pt"
if ($Resume) {
    $model = Join-Path $runsDir "$RunName\weights\last.pt"
    if (-not (Test-Path -LiteralPath $model)) {
        throw "Resume checkpoint not found: $model"
    }
}

Push-Location $backendRoot
try {
    $env:YOLO_CONFIG_DIR = Join-Path $projectRoot ".venv\ultralytics"
    $env:MPLCONFIGDIR = Join-Path $projectRoot ".venv\matplotlib"
    New-Item -ItemType Directory -Force -Path $env:YOLO_CONFIG_DIR, $env:MPLCONFIGDIR | Out-Null
    $args = @(
        "tools\train_yolo.py",
        "--data", $dataYaml,
        "--model", $model,
        "--epochs", $Epochs,
        "--imgsz", $ImageSize,
        "--batch", $Batch,
        "--device", $Device,
        "--optimizer", $Optimizer,
        "--lr0", $LearningRate,
        "--momentum", $Momentum,
        "--workers", "2",
        "--project", $runsDir,
        "--name", $RunName,
        "--exist-ok",
        "--fraction", $Fraction
    )
    if ($DryRun) {
        $args += "--dry-run"
    }
    if ($Resume) {
        $args += "--resume"
    }
    & $python @args
    if ($LASTEXITCODE -ne 0) {
        throw "TT100K training failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
