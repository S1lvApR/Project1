param(
    [string]$RunName = "tt100k_yolo11n_gpu_corrected_sgd_b8",
    [int]$TotalEpochs = 100,
    [int]$RefreshSeconds = 5
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runDir = Join-Path $projectRoot "training\runs\$RunName"
$resultsPath = Join-Path $runDir "results.csv"
$host.UI.RawUI.WindowTitle = "TT100K Live Training Progress"

function Format-Metric([object]$Value) {
    return "{0:N5}" -f [double]$Value
}

while ($true) {
    Clear-Host
    Write-Host "TT100K Live Training Progress" -ForegroundColor Cyan
    Write-Host "Run: $RunName"
    Write-Host "Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "Press Ctrl+C to close this monitor. Training will continue."
    Write-Host ""

    if (-not (Test-Path -LiteralPath $resultsPath)) {
        Write-Host "Waiting for $resultsPath" -ForegroundColor Yellow
        Start-Sleep -Seconds $RefreshSeconds
        continue
    }

    try {
        $rows = @(Import-Csv -LiteralPath $resultsPath)
        if (-not $rows.Count) {
            throw "No completed epochs yet"
        }
        $last = $rows[-1]
        $best = $rows |
            Sort-Object { [double]$_.'metrics/mAP50-95(B)' } -Descending |
            Select-Object -First 1
        $completed = [int]$last.epoch
        $ratio = [Math]::Min(1.0, $completed / [double]$TotalEpochs)
        $filled = [Math]::Floor($ratio * 40)
        $bar = ("#" * $filled).PadRight(40, "-")

        Write-Host ("[{0}] {1,6:N1}%  epoch {2}/{3}" -f $bar, ($ratio * 100), $completed, $TotalEpochs) -ForegroundColor Green
        Write-Host ""
        Write-Host ("train box/cls/dfl : {0}  {1}  {2}" -f `
            (Format-Metric $last.'train/box_loss'), `
            (Format-Metric $last.'train/cls_loss'), `
            (Format-Metric $last.'train/dfl_loss'))
        Write-Host ("precision / recall  : {0}  {1}" -f `
            (Format-Metric $last.'metrics/precision(B)'), `
            (Format-Metric $last.'metrics/recall(B)'))
        Write-Host ("mAP50 / mAP50-95   : {0}  {1}" -f `
            (Format-Metric $last.'metrics/mAP50(B)'), `
            (Format-Metric $last.'metrics/mAP50-95(B)'))
        Write-Host ""
        Write-Host ("best epoch {0}: recall={1}, mAP50-95={2}" -f `
            $best.epoch, `
            (Format-Metric $best.'metrics/recall(B)'), `
            (Format-Metric $best.'metrics/mAP50-95(B)')) -ForegroundColor Yellow
        Write-Host ""
        $gpu = & nvidia-smi `
            --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu `
            --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $gpu) {
            $values = $gpu -split ',' | ForEach-Object { $_.Trim() }
            Write-Host ("GPU: util={0}%  memory={1}/{2} MiB  temp={3} C" -f `
                $values[0], $values[1], $values[2], $values[3]) -ForegroundColor Magenta
        }
        Write-Host ""
        Write-Host "Baseline gate: recall >= 0.31015, mAP50-95 >= 0.11429; one must improve by 10%."
    }
    catch {
        Write-Host "Reading progress: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds $RefreshSeconds
}
