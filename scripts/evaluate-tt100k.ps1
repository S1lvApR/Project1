param(
    [Parameter(Mandatory = $true)]
    [string]$Model,
    [string]$RunName = "tt100k_eval",
    [int]$ImageSize = 1280,
    [int]$Batch = 4,
    [string]$Device = "0"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$python = Join-Path $projectRoot "backend\.venv\Scripts\python.exe"
$runs = Join-Path $projectRoot "training\runs"
$data = Join-Path $projectRoot "training\datasets\tt100k_corrected_45\data.ultralytics.yaml"
$output = Join-Path $runs "$RunName\metrics.json"
$env:YOLO_CONFIG_DIR = Join-Path $projectRoot ".venv\ultralytics"
$env:MPLCONFIGDIR = Join-Path $projectRoot ".venv\matplotlib"

& $python -X utf8 (Join-Path $projectRoot "backend\tools\evaluate_yolo.py") `
    --model (Join-Path $projectRoot $Model) `
    --data $data `
    --output $output `
    --project $runs `
    --name $RunName `
    --imgsz $ImageSize `
    --batch $Batch `
    --device $Device `
    --workers 2
if ($LASTEXITCODE -ne 0) {
    throw "TT100K evaluation failed with exit code $LASTEXITCODE"
}
