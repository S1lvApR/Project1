param(
    [int]$Epochs = 50,
    [int]$ImageSize = 640,
    [int]$Batch = 8,
    [string]$Device = "0",
    [double]$Fraction = 1.0,
    [string]$RunName = "tt100k_yolo11n_gpu",
    [switch]$Resume,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$backendRoot = Join-Path $projectRoot "backend"
$dataYaml = Join-Path $projectRoot "training\datasets\tt100k\data.yaml"
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
    $args = @(
        "tools\train_yolo.py",
        "--data", $dataYaml,
        "--model", $model,
        "--epochs", $Epochs,
        "--imgsz", $ImageSize,
        "--batch", $Batch,
        "--device", $Device,
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
    python @args
}
finally {
    Pop-Location
}
