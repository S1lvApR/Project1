param(
    [string]$Archive = "Train.tar",
    [string]$Output = "training\datasets\gtsrb_cls_final",
    [double]$ValidationRatio = 0.2,
    [int]$Seed = 42
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$archivePath = (Resolve-Path -LiteralPath (Join-Path $projectRoot $Archive)).Path
$expectedHash = "b246382c13e48fe46b05b26dd2778fd4"
$actualHash = (Get-FileHash -Algorithm MD5 -LiteralPath $archivePath).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    throw "Unexpected Train.tar MD5: $actualHash"
}

$sourceRoot = Join-Path $projectRoot "training\raw\gtsrb_final\train_png"
$outputRoot = Join-Path $projectRoot $Output
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    New-Item -ItemType Directory -Path $sourceRoot | Out-Null
    $entries = @(tar.exe -tf $archivePath)
    $unsafe = @($entries | Where-Object {
        $_ -match '(^|/|\\)\.\.(/|\\|$)' -or $_ -match '^[A-Za-z]:' -or $_ -match '^[/\\]'
    })
    if ($unsafe.Count) {
        throw "Unsafe tar entry: $($unsafe[0])"
    }
    tar.exe -xf $archivePath -C $sourceRoot
    if ($LASTEXITCODE -ne 0) {
        throw "tar extraction failed with exit code $LASTEXITCODE"
    }
}
if (Test-Path -LiteralPath $outputRoot) {
    throw "Prepared GTSRB output already exists: $outputRoot"
}

$python = Join-Path $projectRoot "backend\.venv\Scripts\python.exe"
& $python -X utf8 (Join-Path $projectRoot "backend\tools\prepare_gtsrb.py") `
    --source $sourceRoot `
    --output $outputRoot `
    --val-ratio $ValidationRatio `
    --seed $Seed `
    --image-mode hardlink
if ($LASTEXITCODE -ne 0) {
    throw "GTSRB preparation failed with exit code $LASTEXITCODE"
}
