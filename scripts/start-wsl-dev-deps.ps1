$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$normalizedProjectRoot = $projectRoot.Replace("\", "/")

if ($normalizedProjectRoot -notmatch "^([A-Za-z]):/(.*)$") {
    throw "Only local drive paths are supported: $projectRoot"
}

$drive = $Matches[1].ToLowerInvariant()
$path = $Matches[2]
$wslProjectRoot = "/mnt/$drive/$path"

$existing = Get-CimInstance Win32_Process -Filter "name = 'wsl.exe'" |
    Where-Object {
        $_.CommandLine -like "*$wslProjectRoot*" -and
        $_.CommandLine -like "*docker compose up -d*" -and
        $_.CommandLine -like "*exec sleep infinity*"
    }

if ($existing) {
    Write-Host "WSL dev dependencies are already kept alive."
    $existing | Select-Object ProcessId, CommandLine
    exit 0
}

$safeWslProjectRoot = $wslProjectRoot.Replace("'", "'\''")
$bashCommand = "cd '$safeWslProjectRoot' && docker compose up -d && exec sleep infinity"
$arguments = "-e bash -lc ""$bashCommand"""
$process = Start-Process -FilePath "wsl.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru

Write-Host "Started WSL dev dependency keepalive process: $($process.Id)"
Write-Host "PostgreSQL, Redis, and MinIO are exposed on 127.0.0.1 while it is running."
