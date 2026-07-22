Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command Assert-True -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "ProjectEnvironment.Tests.ps1")
}

if (-not (Get-Command Invoke-CheckedCommand -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot "..\lib\ProjectEnvironment.psm1") -Force
}

function Get-BootstrapScriptPath {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\bootstrap-windows.ps1"))
}

function Get-DoctorScriptPath {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\doctor.ps1"))
}

function Get-StartScriptPath {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\start.ps1"))
}

function Get-StopScriptPath {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\stop.ps1"))
}

function New-BootstrapFixture {
    $root = New-TempFixture

    foreach ($relativePath in @(
        "backend",
        "frontend",
        "scripts",
        "scripts\config"
    )) {
        New-Item -ItemType Directory -Path (Join-Path $root $relativePath) | Out-Null
    }

    foreach ($requirementsFile in @(
        "requirements.txt",
        "requirements-core.txt",
        "requirements-cpu.txt",
        "requirements-gpu.txt"
    )) {
        Set-Content -LiteralPath (Join-Path $root "backend\$requirementsFile") -Value "# test fixture" -Encoding ASCII
    }

    Set-Content -LiteralPath (Join-Path $root "frontend\package-lock.json") -Value "{}" -Encoding ASCII
    (New-ValidBootstrapManifestObject | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $root "scripts\config\bootstrap-manifest.json") -Encoding ASCII

    return $root
}

function Get-FixtureMutationTargets {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return @(
        (Join-Path $ProjectRoot ".runtime"),
        (Join-Path $ProjectRoot "models"),
        (Join-Path $ProjectRoot "backend\.env"),
        (Join-Path $ProjectRoot "backend\.venv"),
        (Join-Path $ProjectRoot "backend\logs"),
        (Join-Path $ProjectRoot "frontend\node_modules")
    )
}

function Assert-NoPlanOnlyMutations {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    foreach ($path in (Get-FixtureMutationTargets -ProjectRoot $ProjectRoot)) {
        Assert-False -Condition (Test-Path -LiteralPath $path) -Message "PlanOnly mutated fixture path '$path'."
    }
}

function Assert-NoBootstrapMutations {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    foreach ($path in (Get-FixtureMutationTargets -ProjectRoot $ProjectRoot)) {
        Assert-False -Condition (Test-Path -LiteralPath $path) -Message "Bootstrap mutated fixture path '$path'."
    }
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory = $true)]$Object)

    return ($Object | ConvertTo-Json -Depth 10 -Compress)
}

function Invoke-BootstrapScriptProcess {
    param(
        [string[]]$ArgumentList = @(),
        [string]$ProjectRoot
    )

    $bootstrapScriptPath = Get-BootstrapScriptPath
    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath

    $allArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $bootstrapScriptPath
    )

    if ($ProjectRoot) {
        $allArguments += @("-ProjectRoot", $ProjectRoot)
    }

    if ($ArgumentList) {
        $allArguments += $ArgumentList
    }

    $quotedArguments = foreach ($argument in $allArguments) {
        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }

        '"' + $argument.Replace('"', '\"') + '"'
    }

    $startInfo.Arguments = $quotedArguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-DoctorScriptProcess {
    param(
        [string[]]$ArgumentList = @(),
        [string]$ProjectRoot
    )

    $doctorScriptPath = Get-DoctorScriptPath
    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath

    $allArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $doctorScriptPath
    )

    if ($ProjectRoot) {
        $allArguments += @("-ProjectRoot", $ProjectRoot)
    }

    if ($ArgumentList) {
        $allArguments += $ArgumentList
    }

    $quotedArguments = foreach ($argument in $allArguments) {
        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }

        '"' + $argument.Replace('"', '\"') + '"'
    }

    $startInfo.Arguments = $quotedArguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-StopScriptProcess {
    param(
        [string[]]$ArgumentList = @(),
        [string]$ProjectRoot,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $stopScriptPath = Get-StopScriptPath
    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath

    $allArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $stopScriptPath
    )

    if ($ProjectRoot) {
        $allArguments += @("-ProjectRoot", $ProjectRoot)
    }

    if ($ArgumentList) {
        $allArguments += $ArgumentList
    }

    $quotedArguments = foreach ($argument in $allArguments) {
        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }

        '"' + $argument.Replace('"', '\"') + '"'
    }

    $startInfo.Arguments = $quotedArguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            } catch {
            }

            [void]$process.WaitForExit(5000)
            throw "stop.ps1 timed out after $TimeoutSeconds seconds."
        }

        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-StartScriptProcess {
    param(
        [string[]]$ArgumentList = @(),
        [string]$ProjectRoot,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $startScriptPath = Get-StartScriptPath
    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath

    $allArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $startScriptPath
    )

    if ($ProjectRoot) {
        $allArguments += @("-ProjectRoot", $ProjectRoot)
    }

    if ($ArgumentList) {
        $allArguments += $ArgumentList
    }

    $quotedArguments = foreach ($argument in $allArguments) {
        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }

        '"' + $argument.Replace('"', '\"') + '"'
    }

    $startInfo.Arguments = $quotedArguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            } catch {
            }

            [void]$process.WaitForExit(5000)
            throw "start.ps1 timed out after $TimeoutSeconds seconds."
        }

        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function New-NodeRuntimeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$NodeContent,
        [string]$ArchiveName = "node-runtime.zip"
    )

    $archiveRoot = Join-Path $FixtureRoot ([System.Guid]::NewGuid().ToString("N"))
    $versionRoot = Join-Path $archiveRoot "node-v$Version-win-x64"
    New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $versionRoot "node.exe") -Value $NodeContent -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $versionRoot "npm.cmd") -Value "@echo npm" -Encoding ASCII
    $archivePath = Join-Path $FixtureRoot $ArchiveName
    Compress-Archive -Path (Join-Path $archiveRoot "*") -DestinationPath $archivePath -Force
    Remove-TempFixture -Path $archiveRoot
    return $archivePath
}

function Assert-TestRequiresJunction {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Expected test junction path '$Path' to exist."
    }
}

function Invoke-BootstrapChildScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptContent,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $fixture = New-TempFixture
    $scriptPath = Join-Path $fixture "child.ps1"
    try {
        $modulePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\lib\ProjectEnvironment.psm1")).Replace("'", "''")
        $prefixedContent = @"
Import-Module '$modulePath' -Force
$ScriptContent
"@
        $prefixedContent | Set-Content -LiteralPath $scriptPath -Encoding ASCII
        $powershellPath = Join-Path $PSHOME "powershell.exe"
        return Invoke-CheckedCommand -FilePath $powershellPath -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath
        ) -WorkingDirectory $WorkingDirectory
    } finally {
        Remove-TempFixture -Path $fixture
    }
}

function Set-FixtureManifestModelContents {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][hashtable]$ModelContents
    )

    $manifestPath = Join-Path $ProjectRoot "scripts\config\bootstrap-manifest.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($model in @($manifest.release.models)) {
        if (-not $ModelContents.ContainsKey($model.filename)) {
            continue
        }

        $content = [string]$ModelContents[$model.filename]
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($content)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $model.bytes = $bytes.Length
            $model.sha256 = ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "")
        } finally {
            $sha256.Dispose()
        }
    }

    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding ASCII
}

function New-DoctorFixture {
    $root = New-BootstrapFixture

    foreach ($relativePath in @(
        "backend\data",
        "backend\.venv\Scripts",
        "frontend\node_modules",
        "models"
    )) {
        New-Item -ItemType Directory -Path (Join-Path $root $relativePath) -Force | Out-Null
    }

    $defaultModels = @{
        "tt100k-yolo11s-reference42.pt" = "detector-default"
        "tt100k-yolo11n-common45.pt" = "detector-optional"
        "gtsrb-yolo11n-cls.pt" = "classifier-default"
    }
    Set-FixtureManifestModelContents -ProjectRoot $root -ModelContents $defaultModels

    foreach ($entry in $defaultModels.GetEnumerator()) {
        [System.IO.File]::WriteAllText((Join-Path $root "models\$($entry.Key)"), [string]$entry.Value, [System.Text.Encoding]::ASCII)
    }

    [System.IO.File]::WriteAllText((Join-Path $root "backend\.venv\Scripts\python.exe"), "fixture-python", [System.Text.Encoding]::ASCII)

    $envContent = @(
        "APP_MODE=local",
        "DATABASE_URL=sqlite:///./data/local.db",
        "REDIS_ENABLED=false",
        "MINIO_ENABLED=false",
        "YOLO_MODEL_PATH=../models/tt100k-yolo11s-reference42.pt",
        "YOLO_DEVICE=cpu",
        "GTSRB_MODEL_PATH=../models/gtsrb-yolo11n-cls.pt",
        "GTSRB_DEVICE=cpu",
        "JWT_SECRET_KEY=super-secret-fixture-value"
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $root "backend\.env") -Value ($envContent + "`r`n") -Encoding ASCII

    return $root
}

function New-StartFixture {
    $root = New-DoctorFixture

    foreach ($relativePath in @(
        ".runtime\python",
        ".runtime\node",
        "frontend\node_modules\vite\bin"
    )) {
        New-Item -ItemType Directory -Path (Join-Path $root $relativePath) -Force | Out-Null
    }

    [System.IO.File]::WriteAllText((Join-Path $root ".runtime\python\python.exe"), "fixture-base-python", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $root ".runtime\node\node.exe"), "fixture-node", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $root "frontend\node_modules\vite\bin\vite.js"), "module.exports = {};", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $root "backend\.venv\pyvenv.cfg"), "home = $(Join-Path $root '.runtime\python')`r`n", [System.Text.Encoding]::ASCII)

    return $root
}

function New-StopFixture {
    $root = New-BootstrapFixture
    New-Item -ItemType Directory -Path (Join-Path $root ".runtime\state") -Force | Out-Null
    return $root
}

function Get-StopFixtureStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role
    )

    return Join-Path $ProjectRoot ".runtime\state\$Role.json"
}

function ConvertTo-StopTestArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Start-StopTestChildProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [string]$Secret = "SENTINEL-STOP-SECRET",
        [switch]$SkipIdentityCapture
    )

    $fixture = New-TempFixture
    $scriptPath = Join-Path $fixture "child.ps1"
    $marker = "project-role-$Role"
    $scriptContent = @"
param(
    [Parameter(Mandatory = `$true)][string]`$ManagedProjectRoot,
    [Parameter(Mandatory = `$true)][string]`$ManagedRole,
    [Parameter(Mandatory = `$true)][string]`$Marker,
    [Parameter(Mandatory = `$true)][string]`$Secret
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

while (`$true) {
    Start-Sleep -Milliseconds 250
}
"@
    Set-Content -LiteralPath $scriptPath -Value $scriptContent -Encoding ASCII

    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = (@(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath,
            "-ManagedProjectRoot",
            $ProjectRoot,
            "-ManagedRole",
            $Role,
            "-Marker",
            $marker,
            "-Secret",
            $Secret
        ) | ForEach-Object { ConvertTo-StopTestArgument -Argument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $identity = $null
    if (-not $SkipIdentityCapture) {
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $deadline) {
            if ($process.HasExited) {
                $process.Dispose()
                throw "Stop test child exited before identity capture."
            }

            try {
                $identity = Get-ProjectProcessIdentity -ProcessId $process.Id
                if ($null -ne $identity) {
                    break
                }
            } catch {
            }

            Start-Sleep -Milliseconds 200
        }

        if ($null -eq $identity) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } catch {
            }
            $process.Dispose()
            throw "Stop test child identity was unavailable."
        }
    }

    return [pscustomobject]@{
        Process = $process
        Fixture = $fixture
        ScriptPath = $scriptPath
        ProjectRoot = $ProjectRoot
        Role = $Role
        Marker = $marker
        Secret = $Secret
        Identity = $identity
        IntendedCommandLine = "$powershellPath $($startInfo.Arguments)"
    }
}

function New-StartSyntheticIdentity {
    param(
        [Parameter(Mandatory = $true)]$ProcessHandle,
        [string]$CommandLine = ""
    )

    $executablePath = [string]$ProcessHandle.StartInfo.FileName
    if ([string]::IsNullOrWhiteSpace($executablePath)) {
        $executablePath = [string]$ProcessHandle.Path
    }

    return [pscustomobject]@{
        Pid = [int]$ProcessHandle.Id
        ExecutablePath = $executablePath
        StartTimeUtc = ([datetime]$ProcessHandle.StartTime).ToUniversalTime()
        CommandLine = [string]$CommandLine
    }
}

function New-StartTrackedProcessHandle {
    param([Parameter(Mandatory = $true)]$ProcessHandle)

    $tracker = [pscustomobject]@{ Disposed = $false }
    $tracked = [pscustomobject]@{
        Id = [int]$ProcessHandle.Id
        HasExited = $false
        StartInfo = $ProcessHandle.StartInfo
        StartTime = $ProcessHandle.StartTime
        Path = $ProcessHandle.StartInfo.FileName
        Tracker = $tracker
    }
    $tracked | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Tracker.Disposed = $true }
    return $tracked
}

function Stop-StopTestChildProcess {
    param($Child)

    if ($null -eq $Child) {
        return
    }

    if ($null -ne $Child.Process) {
        try {
            if (-not $Child.Process.HasExited) {
                Stop-Process -Id $Child.Process.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 300
            }
        } catch {
        } finally {
            $Child.Process.Dispose()
        }
    }

    if ($Child.Fixture) {
        Remove-TempFixture -Path $Child.Fixture
    }
}

function New-StopProcessRecord {
    param(
        [Parameter(Mandatory = $true)]$Child,
        [hashtable]$Overrides
    )

    $identity = Get-ProjectProcessIdentity -ProcessId $Child.Process.Id
    $record = [ordered]@{
        schemaVersion = 1
        pid = [int]$identity.Pid
        executablePath = [string]$identity.ExecutablePath
        startTimeUtc = $identity.StartTimeUtc.ToString("o")
        commandLine = [string]$identity.CommandLine
        projectRoot = [string]$Child.ProjectRoot
        role = [string]$Child.Role
    }

    if ($Overrides) {
        foreach ($entry in $Overrides.GetEnumerator()) {
            $record[$entry.Key] = $entry.Value
        }
    }

    return $record
}

function New-StopSyntheticActualIdentity {
    param(
        [Parameter(Mandatory = $true)]$Child,
        [hashtable]$Overrides
    )

    $identity = if ($Child.Identity) { $Child.Identity } else { Get-ProjectProcessIdentity -ProcessId $Child.Process.Id }
    $syntheticCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($Child.ScriptPath)`" -ManagedProjectRoot `"$($Child.ProjectRoot)`" -ManagedRole $($Child.Role) -Marker $($Child.Marker)"
    $actualIdentity = [ordered]@{
        Pid = [int]$identity.Pid
        ExecutablePath = [string]$identity.ExecutablePath
        StartTimeUtc = $identity.StartTimeUtc
        CommandLine = $syntheticCommandLine
    }

    if ($Overrides) {
        foreach ($entry in $Overrides.GetEnumerator()) {
            $actualIdentity[$entry.Key] = $entry.Value
        }
    }

    return [pscustomobject]$actualIdentity
}

function New-StopRecordFromSyntheticIdentity {
    param(
        [Parameter(Mandatory = $true)]$Child,
        [Parameter(Mandatory = $true)]$ActualIdentity,
        [hashtable]$Overrides
    )

    $record = [ordered]@{
        schemaVersion = 1
        pid = [int]$ActualIdentity.Pid
        executablePath = [string]$ActualIdentity.ExecutablePath
        startTimeUtc = ([datetime]$ActualIdentity.StartTimeUtc).ToString("o")
        commandLine = [string]$ActualIdentity.CommandLine
        projectRoot = [string]$Child.ProjectRoot
        role = [string]$Child.Role
    }

    if ($Overrides) {
        foreach ($entry in $Overrides.GetEnumerator()) {
            $record[$entry.Key] = $entry.Value
        }
    }

    return $record
}

function New-StopIdentityComparer {
    param([Parameter(Mandatory = $true)]$ActualIdentity)

    return {
        param($RecordedIdentity, $ProcessId)

        if ([int]$RecordedIdentity.Pid -ne [int]$ActualIdentity.Pid) {
            return $false
        }

        if (-not ([System.IO.Path]::GetFullPath([string]$RecordedIdentity.ExecutablePath)).Equals([System.IO.Path]::GetFullPath([string]$ActualIdentity.ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        $recordedStart = [datetime]::Parse([string]$RecordedIdentity.StartTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
        $actualStart = ([datetime]$ActualIdentity.StartTimeUtc).ToUniversalTime()
        if ($recordedStart -ne $actualStart) {
            return $false
        }

        return ([string]$RecordedIdentity.CommandLine).Equals([string]$ActualIdentity.CommandLine, [System.StringComparison]::Ordinal)
    }.GetNewClosure()
}

function Write-StopProcessRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)]$Record
    )

    $path = Get-StopFixtureStatePath -ProjectRoot $ProjectRoot -Role $Role
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null

    if ($Record -is [string]) {
        Set-Content -LiteralPath $path -Value $Record -Encoding ASCII
    } else {
        Set-Content -LiteralPath $path -Value (ConvertTo-CanonicalJson -Object $Record) -Encoding ASCII
    }

    return $path
}

function Get-NonexistentProcessId {
    $maxProcessId = [int]((Get-Process | Measure-Object -Property Id -Maximum).Maximum)
    $candidate = $maxProcessId + 4096

    while ($true) {
        if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) {
            return $candidate
        }

        $candidate++
    }
}

function Start-TestTcpListener {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()

    return [pscustomobject]@{
        Listener = $listener
        Port = ([int]$listener.LocalEndpoint.Port)
    }
}

function Get-TestTcpPort {
    $reservation = Start-TestTcpListener
    try {
        return $reservation.Port
    } finally {
        $reservation.Listener.Stop()
    }
}

function Get-BootstrapScriptTests {
    return @(
        @{
            Name = "Bootstrap script AST parses cleanly and exposes the expected parameters"
            Body = {
                $bootstrapScriptPath = Get-BootstrapScriptPath
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapScriptPath, [ref]$tokens, [ref]$parseErrors)

                Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "Bootstrap script parse errors were found."

                $attributeText = ($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join " "
                Assert-Contains -ExpectedSubstring "SupportsShouldProcess" -Actual $attributeText -Message "CmdletBinding must advertise SupportsShouldProcess."

                $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $requiredParameterNames = @(
                    "Device",
                    "SkipRuntimeDownload",
                    "SkipModels",
                    "ForceConfig",
                    "Start",
                    "PlanOnly",
                    "ProjectRoot"
                )

                foreach ($parameterName in $requiredParameterNames) {
                    Assert-True -Condition ($parameterNames -contains $parameterName) -Message "Missing required bootstrap parameter '$parameterName'."
                }
            }
        },
        @{
            Name = "Repository frontend commands load Vite config without an esbuild child process"
            Body = {
                $projectRoot = Split-Path -Parent (Split-Path -Parent (Get-BootstrapScriptPath))
                $package = Get-Content -LiteralPath (Join-Path $projectRoot "frontend\package.json") -Raw | ConvertFrom-Json
                foreach ($scriptName in @("dev", "build", "preview", "test", "test:run", "test:coverage")) {
                    $command = [string]$package.scripts.$scriptName
                    Assert-Contains -ExpectedSubstring "--configLoader native" -Actual $command -Message "Frontend script '$scriptName' should use native Vite config loading."
                }
            }
        },
        @{
            Name = "PlanOnly auto gpu emits the stable plan contract and does not mutate the fixture"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "auto",
                        "-NvidiaSmiAvailable",
                        "`$true",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "24"
                    )

                    Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "PlanOnly auto gpu should succeed."
                    $plan = $result.StdOut | ConvertFrom-Json
                    Assert-True -Condition $plan.planOnly -Message "PlanOnly should report planOnly=true."
                    Assert-Equal -Expected "auto" -Actual $plan.requestedDevice -Message "Requested device mismatch."
                    Assert-Equal -Expected "gpu" -Actual $plan.selectedDevice -Message "Selected device mismatch."
                    Assert-Equal -Expected "3.10.11" -Actual $plan.runtime.python.version -Message "Python version mismatch."
                    Assert-Equal -Expected "24.18.0" -Actual $plan.runtime.node.version -Message "Node version mismatch."
                    Assert-Equal -Expected "backend/requirements-gpu.txt" -Actual $plan.requirementsFile -Message "GPU requirements mismatch."
                    Assert-Equal -Expected "npm ci" -Actual $plan.frontend.installCommand -Message "npm plan mismatch."
                    Assert-Equal -Expected "create-if-missing" -Actual $plan.config.action -Message "Config plan mismatch."
                    Assert-Equal -Expected "scripts/doctor.ps1" -Actual $plan.doctor.script -Message "Doctor path mismatch."
                    Assert-False -Condition $plan.start.enabled -Message "Start should be disabled by default."
                    Assert-Equal -Expected @(
                        "tt100k-yolo11s-reference42.pt",
                        "gtsrb-yolo11n-cls.pt"
                    ) -Actual @($plan.models | ForEach-Object { $_.filename }) -Message "Default models mismatch."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PlanOnly auto cpu emits the stable plan contract and does not mutate the fixture"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "auto",
                        "-NvidiaSmiAvailable",
                        "`$false",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8",
                        "-SkipModels",
                        "-ForceConfig",
                        "-Start"
                    )

                    Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "PlanOnly auto cpu should succeed."
                    $plan = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "cpu" -Actual $plan.selectedDevice -Message "Selected device mismatch."
                    Assert-Equal -Expected "backend/requirements-cpu.txt" -Actual $plan.requirementsFile -Message "CPU requirements mismatch."
                    Assert-Equal -Expected 0 -Actual @($plan.models).Count -Message "SkipModels should remove model downloads from the plan."
                    Assert-Equal -Expected "replace" -Actual $plan.config.action -Message "ForceConfig should replace the config."
                    Assert-True -Condition $plan.start.enabled -Message "Start should be enabled when requested."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PlanOnly forced cpu never selects GPU requirements"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "cpu",
                        "-NvidiaSmiAvailable",
                        "`$true",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8"
                    )

                    Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "PlanOnly cpu should succeed."
                    $plan = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "cpu" -Actual $plan.selectedDevice -Message "Selected device mismatch."
                    Assert-Equal -Expected "backend/requirements-cpu.txt" -Actual $plan.requirementsFile -Message "Forced cpu should keep CPU requirements."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "WhatIf returns the same stable plan contract and does not mutate or run follow-up scripts"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\doctor.ps1") -Value "Set-Content -LiteralPath '$fixture\doctor-ran.txt' -Value 'doctor'" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\start.ps1") -Value "Set-Content -LiteralPath '$fixture\start-ran.txt' -Value 'start'" -Encoding ASCII

                    $planOnly = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "cpu",
                        "-SkipRuntimeDownload",
                        "-DisablePathRuntimeProbe",
                        "-SkipModels",
                        "-ForceConfig",
                        "-Start",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8"
                    )
                    Assert-Equal -Expected 0 -Actual $planOnly.ExitCode -Message "PlanOnly baseline should succeed."

                    $whatIf = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-WhatIf",
                        "-Device",
                        "cpu",
                        "-SkipRuntimeDownload",
                        "-DisablePathRuntimeProbe",
                        "-SkipModels",
                        "-ForceConfig",
                        "-Start",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8"
                    )

                    Assert-Equal -Expected 0 -Actual $whatIf.ExitCode -Message "WhatIf should succeed."
                    $planOnlyPlan = $planOnly.StdOut | ConvertFrom-Json
                    $whatIfPlan = $whatIf.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected (ConvertTo-CanonicalJson -Object $planOnlyPlan) -Actual (ConvertTo-CanonicalJson -Object $whatIfPlan) -Message "WhatIf plan contract mismatch."
                    Assert-NoBootstrapMutations -ProjectRoot $fixture
                    Assert-False -Condition (Test-Path -LiteralPath (Join-Path $fixture "doctor-ran.txt")) -Message "WhatIf must not run doctor.ps1."
                    Assert-False -Condition (Test-Path -LiteralPath (Join-Path $fixture "start-ran.txt")) -Message "WhatIf must not run start.ps1."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PlanOnly without ProjectRoot defaults to the repository root"
            Body = {
                $result = Invoke-BootstrapScriptProcess -ArgumentList @(
                    "-PlanOnly",
                    "-Device",
                    "cpu",
                    "-OsArchitectureOverride",
                    "x64",
                    "-FreeSpaceGbOverride",
                    "8",
                    "-SkipModels"
                )

                Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "PlanOnly without ProjectRoot should succeed."
                $plan = $result.StdOut | ConvertFrom-Json
                $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
                Assert-Equal -Expected $expectedRoot -Actual $plan.projectRoot -Message "Default ProjectRoot mismatch."
            }
        },
        @{
            Name = "Forced gpu fails when Nvidia support is unavailable"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "gpu",
                        "-NvidiaSmiAvailable",
                        "`$false",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "24"
                    )

                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Forced gpu should fail without Nvidia."
                    Assert-Contains -ExpectedSubstring "GPU mode requires Nvidia support" -Actual ($result.StdOut + $result.StdErr) -Message "GPU failure message mismatch."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PlanOnly fails when the bootstrap manifest is missing"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    Remove-Item -LiteralPath (Join-Path $fixture "scripts\config\bootstrap-manifest.json") -Force
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "cpu",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8"
                    )

                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Missing manifest should fail."
                    Assert-Contains -ExpectedSubstring "bootstrap-manifest.json" -Actual ($result.StdOut + $result.StdErr) -Message "Missing manifest failure should mention the manifest path."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PlanOnly rejects a non-x64 architecture override"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "cpu",
                        "-OsArchitectureOverride",
                        "x86",
                        "-FreeSpaceGbOverride",
                        "8"
                    )

                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Non-x64 architecture should fail."
                    Assert-Contains -ExpectedSubstring "Windows x64" -Actual ($result.StdOut + $result.StdErr) -Message "Architecture failure message mismatch."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PlanOnly rejects manifest entries that escape the project root"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $manifestPath = Join-Path $fixture "scripts\config\bootstrap-manifest.json"
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                    $manifest.runtime.python.filename = "..\python-3.10.11-amd64.exe"
                    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $manifestPath -Encoding ASCII

                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-PlanOnly",
                        "-Device",
                        "cpu",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8"
                    )

                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Escaping manifest filename should fail."
                    Assert-Contains -ExpectedSubstring "runtime.python.filename" -Actual ($result.StdOut + $result.StdErr) -Message "Manifest validation failure mismatch."
                    Assert-NoPlanOnlyMutations -ProjectRoot $fixture
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Atomic Node replacement validates staging first and restores the prior runtime on swap failure"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $runtimeRoot = Join-Path $fixture ".runtime"
                    $nodeRoot = Join-Path $runtimeRoot "node"
                    $nodeTempRoot = Join-Path $runtimeRoot "tmp"
                    New-Item -ItemType Directory -Path $nodeRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $nodeRoot "node.exe") -Value "old-version" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $nodeRoot "npm.cmd") -Value "old-npm" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $nodeRoot "marker.txt") -Value "old-marker" -Encoding ASCII
                    $archivePath = New-NodeRuntimeArchive -FixtureRoot $fixture -Version "24.18.0" -NodeContent "24.18.0" -ArchiveName "node-good.zip"

                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedArchive = $archivePath.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$paths = [pscustomobject]@{
    Root = '$escapedFixture'
    RuntimeRoot = '$escapedFixture\.runtime'
    NodeRoot = '$escapedFixture\.runtime\node'
    NodeTempRoot = '$escapedFixture\.runtime\tmp'
}
`$versionResolver = {
    param(`$NodePath)
    [System.IO.File]::ReadAllText(`$NodePath).Trim()
}
`$null = Install-NodeRuntimeAtomically -Paths `$paths -ZipPath '$escapedArchive' -ExpectedVersion '24.18.0' -NodeVersionResolver `$versionResolver
`$afterSuccess = [ordered]@{
    NodeContent = [System.IO.File]::ReadAllText((Join-Path `$paths.NodeRoot 'node.exe')).Trim()
    MarkerExists = Test-Path -LiteralPath (Join-Path `$paths.NodeRoot 'marker.txt')
}
try {
    `$null = Install-NodeRuntimeAtomically -Paths `$paths -ZipPath '$escapedArchive' -ExpectedVersion '24.18.0' -NodeVersionResolver { param(`$NodePath) '0.0.0' }
    throw 'Expected atomic swap failure.'
} catch {
    [ordered]@{
        SuccessNodeContent = `$afterSuccess.NodeContent
        SuccessMarkerExists = `$afterSuccess.MarkerExists
        FailureMessage = `$_.Exception.Message
        RestoredNodeContent = [System.IO.File]::ReadAllText((Join-Path `$paths.NodeRoot 'node.exe')).Trim()
        RestoredMarkerExists = Test-Path -LiteralPath (Join-Path `$paths.NodeRoot 'marker.txt')
        BackupCount = @((Get-ChildItem -LiteralPath `$paths.RuntimeRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like 'node-backup-*' })).Count
        TempCount = if (Test-Path -LiteralPath `$paths.NodeTempRoot) { @((Get-ChildItem -LiteralPath `$paths.NodeTempRoot -Force -ErrorAction SilentlyContinue)).Count } else { 0 }
    } | ConvertTo-Json -Compress
}
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "24.18.0" -Actual $state.SuccessNodeContent -Message "Successful swap should install the staged runtime."
                    Assert-False -Condition $state.SuccessMarkerExists -Message "Successful swap should replace the old runtime contents."
                    Assert-Contains -ExpectedSubstring "Node version mismatch" -Actual $state.FailureMessage -Message "Failed swap should surface version validation failure."
                    Assert-Equal -Expected "24.18.0" -Actual $state.RestoredNodeContent -Message "Failed swap should restore the last known-good runtime."
                    Assert-False -Condition $state.RestoredMarkerExists -Message "Failed swap should not restore the original pre-success marker after the new runtime became known-good."
                    Assert-Equal -Expected 0 -Actual $state.BackupCount -Message "Backups should be cleaned after restore."
                    Assert-Equal -Expected 0 -Actual $state.TempCount -Message "Staging directories should be cleaned."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Atomic Python replacement validates staging first and restores the prior runtime on swap failure"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $runtimeRoot = Join-Path $fixture ".runtime"
                    $pythonRoot = Join-Path $runtimeRoot "python"
                    $downloadsRoot = Join-Path $runtimeRoot "downloads"
                    New-Item -ItemType Directory -Path $pythonRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $downloadsRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $pythonRoot "python.exe") -Value "3.10.10" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $pythonRoot "marker.txt") -Value "old-python" -Encoding ASCII
                    $installerPath = Join-Path $downloadsRoot "python-installer.exe"
                    Set-Content -LiteralPath $installerPath -Value "fake-installer" -Encoding ASCII

                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedInstaller = $installerPath.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$paths = [pscustomobject]@{
    Root = '$escapedFixture'
    RuntimeRoot = '$escapedFixture\.runtime'
    DownloadsRoot = '$escapedFixture\.runtime\downloads'
    PythonRoot = '$escapedFixture\.runtime\python'
}
`$installer = {
    param(`$InstallerPath, `$TargetDir)
    New-Item -ItemType Directory -Path `$TargetDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$TargetDir 'python.exe') -Value '3.10.11' -Encoding ASCII
}
`$versionResolver = {
    param(`$PythonPath)
    [System.IO.File]::ReadAllText(`$PythonPath).Trim()
}
`$null = Install-PythonRuntimeAtomically -Paths `$paths -InstallerPath '$escapedInstaller' -ExpectedVersion '3.10.11' -InstallerInvoker `$installer -PythonVersionResolver `$versionResolver
`$afterSuccess = [ordered]@{
    PythonContent = [System.IO.File]::ReadAllText((Join-Path `$paths.PythonRoot 'python.exe')).Trim()
    MarkerExists = Test-Path -LiteralPath (Join-Path `$paths.PythonRoot 'marker.txt')
}
try {
    `$null = Install-PythonRuntimeAtomically -Paths `$paths -InstallerPath '$escapedInstaller' -ExpectedVersion '3.10.11' -InstallerInvoker {
        param(`$InstallerPath, `$TargetDir)
        New-Item -ItemType Directory -Path `$TargetDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path `$TargetDir 'python.exe') -Value '0.0.0' -Encoding ASCII
    } -PythonVersionResolver `$versionResolver
    throw 'Expected atomic python swap failure.'
} catch {
    [ordered]@{
        SuccessPythonContent = `$afterSuccess.PythonContent
        SuccessMarkerExists = `$afterSuccess.MarkerExists
        FailureMessage = `$_.Exception.Message
        RestoredPythonContent = [System.IO.File]::ReadAllText((Join-Path `$paths.PythonRoot 'python.exe')).Trim()
        RestoredMarkerExists = Test-Path -LiteralPath (Join-Path `$paths.PythonRoot 'marker.txt')
        BackupCount = @((Get-ChildItem -LiteralPath `$paths.RuntimeRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like 'python-backup-*' })).Count
        StageCount = @((Get-ChildItem -LiteralPath `$paths.RuntimeRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like 'python-stage-*' })).Count
    } | ConvertTo-Json -Compress
}
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "3.10.11" -Actual $state.SuccessPythonContent -Message "Successful swap should install the staged Python runtime."
                    Assert-False -Condition $state.SuccessMarkerExists -Message "Successful swap should replace the old Python runtime contents."
                    Assert-Contains -ExpectedSubstring "Python version mismatch" -Actual $state.FailureMessage -Message "Failed swap should surface version validation failure."
                    Assert-Equal -Expected "3.10.11" -Actual $state.RestoredPythonContent -Message "Failed swap should restore the last known-good Python runtime."
                    Assert-False -Condition $state.RestoredMarkerExists -Message "Failed swap should not restore the original pre-success marker after the new runtime became known-good."
                    Assert-Equal -Expected 0 -Actual $state.BackupCount -Message "Python backups should be cleaned after restore."
                    Assert-Equal -Expected 0 -Actual $state.StageCount -Message "Python staging directories should be cleaned."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Atomic Python replacement keeps the valid runtime when old backup cleanup fails"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $runtimeRoot = Join-Path $fixture ".runtime"
                    $pythonRoot = Join-Path $runtimeRoot "python"
                    $downloadsRoot = Join-Path $runtimeRoot "downloads"
                    New-Item -ItemType Directory -Path $pythonRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $downloadsRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $pythonRoot "python.exe") -Value "3.10.10" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $pythonRoot "original.txt") -Value "old-python" -Encoding ASCII
                    $installerPath = Join-Path $downloadsRoot "python-installer.exe"
                    Set-Content -LiteralPath $installerPath -Value "fake-installer" -Encoding ASCII

                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedInstaller = $installerPath.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
`$WarningPreference = 'SilentlyContinue'
. '$scriptPath'
`$paths = [pscustomobject]@{
    Root = '$escapedFixture'
    RuntimeRoot = '$escapedFixture\.runtime'
    DownloadsRoot = '$escapedFixture\.runtime\downloads'
    PythonRoot = '$escapedFixture\.runtime\python'
}
function Remove-IfExists {
    param([string]`$Path, [string]`$RootPath)
    if ([System.IO.Path]::GetFileName(`$Path) -like 'python-backup-*') {
        throw 'SENTINEL-PYTHON-BACKUP-CLEANUP-FAILED'
    }
    if (Test-Path -LiteralPath `$Path) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath `$Path -Force -Recurse
    }
}
`$installedPath = Install-PythonRuntimeAtomically -Paths `$paths -InstallerPath '$escapedInstaller' -ExpectedVersion '3.10.11' -InstallerInvoker {
    param(`$InstallerPath, `$TargetDir)
    New-Item -ItemType Directory -Path `$TargetDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$TargetDir 'python.exe') -Value '3.10.11' -Encoding ASCII
} -PythonVersionResolver {
    param(`$PythonPath)
    [System.IO.File]::ReadAllText(`$PythonPath).Trim()
}
`$backup = Get-ChildItem -LiteralPath `$paths.RuntimeRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like 'python-backup-*' } | Select-Object -First 1
[ordered]@{
    InstalledPath = `$installedPath
    InstalledContent = [System.IO.File]::ReadAllText((Join-Path `$paths.PythonRoot 'python.exe')).Trim()
    OriginalRestored = Test-Path -LiteralPath (Join-Path `$paths.PythonRoot 'original.txt')
    BackupCount = @((Get-ChildItem -LiteralPath `$paths.RuntimeRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like 'python-backup-*' })).Count
    BackupPreserved = `$null -ne `$backup -and (Test-Path -LiteralPath (Join-Path `$backup.FullName 'original.txt'))
} | ConvertTo-Json -Compress
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected (Join-Path $pythonRoot "python.exe") -Actual $state.InstalledPath -Message "Python cleanup failure should still return the valid runtime path."
                    Assert-Equal -Expected "3.10.11" -Actual $state.InstalledContent -Message "Python cleanup failure should keep the valid new runtime."
                    Assert-False -Condition $state.OriginalRestored -Message "Python cleanup failure must not restore the old runtime over a valid install."
                    Assert-Equal -Expected 1 -Actual $state.BackupCount -Message "Python cleanup failure should preserve one old-runtime backup."
                    Assert-True -Condition $state.BackupPreserved -Message "Python cleanup failure should preserve the old runtime contents."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "PATH runtime probes return the first command when multiple applications match"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-Command {
    param([string]`$Name)
    switch (`$Name) {
        'python.exe' { @([pscustomobject]@{ Source = 'C:\first\python.exe' }, [pscustomobject]@{ Source = 'C:\second\python.exe' }) }
        'node.exe' { @([pscustomobject]@{ Source = 'C:\first\node.exe' }, [pscustomobject]@{ Source = 'C:\second\node.exe' }) }
        'npm.cmd' { @([pscustomobject]@{ Source = 'C:\first\npm.cmd' }, [pscustomobject]@{ Source = 'C:\second\npm.cmd' }) }
        default { `$null }
    }
}
[ordered]@{
    Python = Get-PythonCommandFromPath
    Node = Get-NodeCommandFromPath
    Npm = Get-NpmCommandFromPath
} | ConvertTo-Json -Compress
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 'C:\first\python.exe' -Actual $state.Python -Message "Python PATH probe should return one command path."
                    Assert-Equal -Expected 'C:\first\node.exe' -Actual $state.Node -Message "Node PATH probe should return one command path."
                    Assert-Equal -Expected 'C:\first\npm.cmd' -Actual $state.Npm -Message "npm PATH probe should return one command path."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Default Python resolution reuses an exact PATH runtime before downloading"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-PythonCommandFromPath {
    param([switch]`$DisableProbe)
    'C:\compatible-path\python.exe'
}
function Get-ExactPythonVersion {
    param([string]`$PythonPath)
    '3.10.11'
}
function Get-PythonArchitecture {
    param([string]`$PythonPath)
    64
}
function Invoke-DownloadWithHashValidation {
    throw 'SENTINEL-PYTHON-DOWNLOAD-CALLED'
}
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path (Join-Path '$escapedFixture' 'scripts\config\bootstrap-manifest.json')
Resolve-PythonRuntime -Paths `$paths -Manifest `$manifest
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Equal -Expected 'C:\compatible-path\python.exe' -Actual $result.StdOut.Trim() -Message "Default Python resolution should reuse an exact PATH runtime."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Default Python resolution reuses an exact registered runtime before downloading"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-PythonCommandFromPath {
    param([switch]`$DisableProbe)
    'C:\incompatible-path\python.exe'
}
function Get-PythonCommandsFromRegistry {
    param([switch]`$DisableProbe)
    @('C:\registered\python.exe')
}
function Get-ExactPythonVersion {
    param([string]`$PythonPath)
    if (`$PythonPath -eq 'C:\registered\python.exe') { '3.10.11' } else { '3.14.0' }
}
function Get-PythonArchitecture {
    param([string]`$PythonPath)
    64
}
function Invoke-DownloadWithHashValidation {
    throw 'SENTINEL-PYTHON-DOWNLOAD-CALLED'
}
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path (Join-Path '$escapedFixture' 'scripts\config\bootstrap-manifest.json')
Resolve-PythonRuntime -Paths `$paths -Manifest `$manifest
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Equal -Expected 'C:\registered\python.exe' -Actual $result.StdOut.Trim() -Message "Default Python resolution should reuse an exact registered runtime."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Python resolution skips an exact x86 runtime and selects an exact x64 runtime"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-PythonCommandFromPath {
    param([switch]`$DisableProbe)
    'C:\x86\python.exe'
}
function Get-PythonCommandsFromRegistry {
    param([switch]`$DisableProbe)
    @('C:\x64\python.exe')
}
function Get-ExactPythonVersion {
    param([string]`$PythonPath)
    '3.10.11'
}
function Get-PythonArchitecture {
    param([string]`$PythonPath)
    if (`$PythonPath -eq 'C:\x64\python.exe') { 64 } else { 32 }
}
function Invoke-DownloadWithHashValidation {
    throw 'SENTINEL-PYTHON-DOWNLOAD-CALLED'
}
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path (Join-Path '$escapedFixture' 'scripts\config\bootstrap-manifest.json')
Resolve-PythonRuntime -Paths `$paths -Manifest `$manifest
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Equal -Expected 'C:\x64\python.exe' -Actual $result.StdOut.Trim() -Message "Python resolution should skip an x86 candidate even when its version matches."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Python resolution returns a valid PATH runtime without enumerating broken registry data"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-PythonCommandFromPath {
    param([switch]`$DisableProbe)
    'C:\compatible-path\python.exe'
}
function Get-PythonCommandsFromRegistry {
    param([switch]`$DisableProbe)
    throw 'SENTINEL-BROKEN-PYTHON-REGISTRY'
}
function Get-ExactPythonVersion {
    param([string]`$PythonPath)
    '3.10.11'
}
function Get-PythonArchitecture {
    param([string]`$PythonPath)
    64
}
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path (Join-Path '$escapedFixture' 'scripts\config\bootstrap-manifest.json')
Resolve-PythonRuntime -Paths `$paths -Manifest `$manifest
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Equal -Expected 'C:\compatible-path\python.exe' -Actual $result.StdOut.Trim() -Message "A valid PATH runtime should short-circuit broken registry discovery."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Python registry discovery skips a broken entry and keeps later valid entries"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $registeredPython = Join-Path $fixture "registered-python.exe"
                    Set-Content -LiteralPath $registeredPython -Value "fake-python" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedRegisteredPython = $registeredPython.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$versionKeyReader = {
    param(`$RegistryRoot)
    if (`$RegistryRoot -like '*HKEY_CURRENT_USER*') {
        return @([pscustomobject]@{ Name = 'broken' }, [pscustomobject]@{ Name = 'valid' })
    }
    return @()
}
`$installPathReader = {
    param(`$VersionKey)
    if (`$VersionKey.Name -eq 'broken') {
        throw 'SENTINEL-BROKEN-PYTHON-REGISTRY-ENTRY'
    }
    return @('$escapedRegisteredPython')
}
@(Get-PythonCommandsFromRegistry -RegistryVersionKeyReader `$versionKeyReader -RegistryInstallPathReader `$installPathReader) | ConvertTo-Json -Compress
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $paths = @($result.StdOut | ConvertFrom-Json)
                    Assert-Equal -Expected @($registeredPython) -Actual $paths -Message "A broken registry entry should not hide later valid Python registrations."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "SkipRuntimeDownload rejects node and npm resolved from different directories"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $nodeDir = Join-Path $fixture "path-node"
                    $npmDir = Join-Path $fixture "path-npm"
                    New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
                    New-Item -ItemType Directory -Path $npmDir -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $nodeDir "node.exe") -Value "fake-node" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $nodeDir "node.cmd") -Value "@echo node" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $npmDir "npm.cmd") -Value "@echo npm" -Encoding ASCII

                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedNodeDir = $nodeDir.Replace("'", "''")
                    $escapedNpmDir = $npmDir.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-NodeCommandFromPath {
    param([switch]`$DisableProbe)
    '$escapedNodeDir\node.exe'
}
function Get-ExactNodeVersion {
    param(`$NodePath)
    '24.18.0'
}
`$env:PATH = '$escapedNodeDir;$escapedNpmDir;' + `$env:PATH
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path (Join-Path '$escapedFixture' 'scripts\config\bootstrap-manifest.json')
try {
    `$null = Resolve-NodeRuntime -Paths `$paths -Manifest `$manifest -SkipDownload -DisablePathProbe:`$false
    throw 'Expected mismatched PATH runtime failure.'
} catch {
    `$_.Exception.Message
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Contains -ExpectedSubstring "same directory" -Actual $result.StdOut.Trim() -Message "Node/npm pairing failure should mention the resolved node directory requirement."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "SkipRuntimeDownload rejects a matching Node runtime when npm cannot execute"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $nodeRoot = Join-Path $fixture ".runtime\node"
                    New-Item -ItemType Directory -Path $nodeRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $nodeRoot "node.exe") -Value "fake-node" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $nodeRoot "npm.cmd") -Value "fake-npm" -Encoding ASCII

                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Get-ExactNodeVersion {
    param(`$NodePath)
    '24.18.0'
}
function Test-NpmRuntime {
    param(`$NpmPath, `$WorkingDirectory)
    `$false
}
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path (Join-Path '$escapedFixture' 'scripts\config\bootstrap-manifest.json')
try {
    `$null = Resolve-NodeRuntime -Paths `$paths -Manifest `$manifest -SkipDownload -DisablePathProbe
    throw 'Expected unusable npm runtime failure.'
} catch {
    `$_.Exception.Message
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Contains -ExpectedSubstring "npm" -Actual $result.StdOut.Trim().ToLowerInvariant() -Message "Unusable npm runtime failure should identify npm."
                    Assert-False -Condition ($result.StdOut.Contains("Expected unusable npm runtime failure.")) -Message "A matching Node version must not hide an unusable npm runtime."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Auto GPU fallback recreates the target venv and installs CPU cleanly"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $backendRoot = Join-Path $fixture "backend"
                    $venvRoot = Join-Path $backendRoot ".venv"
                    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $venvRoot "original.txt") -Value "old-env" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
`$log = New-Object System.Collections.Generic.List[string]
`$createAttempts = 0
`$null = Install-BackendPythonEnvironment -Paths `$paths -PythonPath 'fake-python.exe' -RequestedDevice 'auto' -InitialDevice 'gpu' -CpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-cpu.txt') -GpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-gpu.txt') -VenvCreator {
    param(`$PythonPath, `$TargetPath)
    `$script:createAttempts++
    `$attempt = `$script:createAttempts
    New-Item -ItemType Directory -Path (Join-Path `$TargetPath 'Scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$TargetPath 'Scripts\python.exe') -Value "venv-`$attempt" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path `$TargetPath "created-`$attempt.txt") -Value "attempt-`$attempt" -Encoding ASCII
    `$log.Add("create:`$attempt")
} -RequirementsInstaller {
    param(`$PythonPath, `$RequirementsPath, `$WorkingDirectory)
    `$log.Add("install:" + [System.IO.Path]::GetFileName(`$RequirementsPath))
} -CudaSelfTester {
    param(`$PythonPath)
    `$log.Add('cuda:false')
    `$false
}
[ordered]@{
    Log = @(`$log)
    SelectedDevice = 'cpu'
    OriginalRestored = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'original.txt')
    Created1Exists = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'created-1.txt')
    Created2Exists = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'created-2.txt')
    BackupCount = @((Get-ChildItem -LiteralPath `$paths.BackendRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like '.venv-backup-*' })).Count
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected @("create:1","install:requirements-gpu.txt","cuda:false","create:2","install:requirements-cpu.txt") -Actual @($state.Log) -Message "Auto GPU fallback call order mismatch."
                    Assert-False -Condition $state.OriginalRestored -Message "Successful fallback should not restore the original venv."
                    Assert-False -Condition $state.Created1Exists -Message "Fallback should remove the first GPU venv before recreating CPU."
                    Assert-True -Condition $state.Created2Exists -Message "Fallback should create a second fresh CPU venv."
                    Assert-Equal -Expected 0 -Actual $state.BackupCount -Message "Successful fallback should clean the venv backup."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Forced GPU failure restores the original venv backup"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $backendRoot = Join-Path $fixture "backend"
                    $venvRoot = Join-Path $backendRoot ".venv"
                    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $venvRoot "original.txt") -Value "old-env" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
try {
    Install-BackendPythonEnvironment -Paths `$paths -PythonPath 'fake-python.exe' -RequestedDevice 'gpu' -InitialDevice 'gpu' -CpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-cpu.txt') -GpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-gpu.txt') -VenvCreator {
        param(`$PythonPath, `$TargetPath)
        New-Item -ItemType Directory -Path (Join-Path `$TargetPath 'Scripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path `$TargetPath 'Scripts\python.exe') -Value 'venv-gpu' -Encoding ASCII
    } -RequirementsInstaller {
        param(`$PythonPath, `$RequirementsPath, `$WorkingDirectory)
    } -CudaSelfTester {
        param(`$PythonPath)
        `$false
    } | Out-Null
    throw 'Expected forced GPU failure.'
} catch {
    [ordered]@{
        Message = `$_.Exception.Message
        OriginalRestored = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'original.txt')
        BackupCount = @((Get-ChildItem -LiteralPath `$paths.BackendRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like '.venv-backup-*' })).Count
    } | ConvertTo-Json -Compress
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Contains -ExpectedSubstring "GPU mode requires torch CUDA self-test to succeed" -Actual $state.Message -Message "Forced GPU failure should surface the CUDA self-test failure."
                    Assert-True -Condition $state.OriginalRestored -Message "Forced GPU failure should restore the original venv."
                    Assert-Equal -Expected 0 -Actual $state.BackupCount -Message "Forced GPU failure should clean the venv backup after restore."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Backend environment rollback preserves the backup when partial cleanup fails"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $backendRoot = Join-Path $fixture "backend"
                    $venvRoot = Join-Path $backendRoot ".venv"
                    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $venvRoot "original.txt") -Value "old-env" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
function Remove-IfExists {
    param([string]`$Path, [string]`$RootPath)
    if (`$Path -eq `$paths.VenvRoot) {
        throw 'SENTINEL-CLEANUP-FAILED'
    }
    if (Test-Path -LiteralPath `$Path) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath `$Path -Force -Recurse
    }
}
try {
    Install-BackendPythonEnvironment -Paths `$paths -PythonPath 'fake-python.exe' -RequestedDevice 'gpu' -InitialDevice 'gpu' -CpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-cpu.txt') -GpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-gpu.txt') -VenvCreator {
        param(`$PythonPath, `$TargetPath)
        New-Item -ItemType Directory -Path (Join-Path `$TargetPath 'Scripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path `$TargetPath 'Scripts\python.exe') -Value 'partial-venv' -Encoding ASCII
    } -RequirementsInstaller {
        param(`$PythonPath, `$RequirementsPath, `$WorkingDirectory)
        throw 'SENTINEL-INSTALL-FAILED'
    } -CudaSelfTester {
        param(`$PythonPath)
        `$true
    } | Out-Null
    throw 'Expected backend environment failure.'
} catch {
    `$backup = Get-ChildItem -LiteralPath `$paths.BackendRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like '.venv-backup-*' } | Select-Object -First 1
    [ordered]@{
        Message = `$_.Exception.Message
        PartialExists = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'Scripts\python.exe')
        BackupCount = @((Get-ChildItem -LiteralPath `$paths.BackendRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like '.venv-backup-*' })).Count
        BackupPreserved = `$null -ne `$backup -and (Test-Path -LiteralPath (Join-Path `$backup.FullName 'original.txt'))
    } | ConvertTo-Json -Compress
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Contains -ExpectedSubstring "SENTINEL-INSTALL-FAILED" -Actual $state.Message -Message "Rollback failure should retain the original installation error."
                    Assert-Contains -ExpectedSubstring "SENTINEL-CLEANUP-FAILED" -Actual $state.Message -Message "Rollback failure should report the cleanup error."
                    Assert-True -Condition $state.PartialExists -Message "Failed cleanup fixture should leave the partial environment in place."
                    Assert-Equal -Expected 1 -Actual $state.BackupCount -Message "Failed cleanup must preserve exactly one prior-environment backup."
                    Assert-True -Condition $state.BackupPreserved -Message "Failed cleanup must preserve the prior environment contents."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Backend environment keeps the valid venv when old backup cleanup fails"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $backendRoot = Join-Path $fixture "backend"
                    $venvRoot = Join-Path $backendRoot ".venv"
                    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $venvRoot "original.txt") -Value "old-env" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
`$WarningPreference = 'SilentlyContinue'
. '$scriptPath'
`$paths = Resolve-ProjectPaths -RootPath '$escapedFixture'
function Remove-IfExists {
    param([string]`$Path, [string]`$RootPath)
    if ([System.IO.Path]::GetFileName(`$Path) -like '.venv-backup-*') {
        throw 'SENTINEL-VENV-BACKUP-CLEANUP-FAILED'
    }
    if (Test-Path -LiteralPath `$Path) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath `$Path -Force -Recurse
    }
}
`$installed = Install-BackendPythonEnvironment -Paths `$paths -PythonPath 'fake-python.exe' -RequestedDevice 'cpu' -InitialDevice 'cpu' -CpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-cpu.txt') -GpuRequirementsPath (Join-Path `$paths.BackendRoot 'requirements-gpu.txt') -VenvCreator {
    param(`$PythonPath, `$TargetPath)
    New-Item -ItemType Directory -Path (Join-Path `$TargetPath 'Scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$TargetPath 'Scripts\python.exe') -Value 'valid-venv' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path `$TargetPath 'installed.txt') -Value 'new-env' -Encoding ASCII
} -RequirementsInstaller {
    param(`$PythonPath, `$RequirementsPath, `$WorkingDirectory)
} -CudaSelfTester {
    param(`$PythonPath)
    `$true
}
`$backup = Get-ChildItem -LiteralPath `$paths.BackendRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like '.venv-backup-*' } | Select-Object -First 1
[ordered]@{
    SelectedDevice = `$installed.SelectedDevice
    NewEnvironmentExists = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'installed.txt')
    OriginalRestored = Test-Path -LiteralPath (Join-Path `$paths.VenvRoot 'original.txt')
    BackupCount = @((Get-ChildItem -LiteralPath `$paths.BackendRoot -Directory -ErrorAction SilentlyContinue | Where-Object { `$_.Name -like '.venv-backup-*' })).Count
    BackupPreserved = `$null -ne `$backup -and (Test-Path -LiteralPath (Join-Path `$backup.FullName 'original.txt'))
} | ConvertTo-Json -Compress
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "cpu" -Actual $state.SelectedDevice -Message "Venv cleanup failure should still return the selected device."
                    Assert-True -Condition $state.NewEnvironmentExists -Message "Venv cleanup failure should keep the valid new environment."
                    Assert-False -Condition $state.OriginalRestored -Message "Venv cleanup failure must not restore the old environment over a valid install."
                    Assert-Equal -Expected 1 -Actual $state.BackupCount -Message "Venv cleanup failure should preserve one old-environment backup."
                    Assert-True -Condition $state.BackupPreserved -Message "Venv cleanup failure should preserve the old environment contents."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Assert-NoReparsePointTraversal rejects junction descendants"
            Body = {
                $fixture = New-BootstrapFixture
                $external = New-TempFixture
                try {
                    $junctionPath = Join-Path $fixture "backend\linked"
                    New-Item -ItemType Directory -Path $external -Force | Out-Null
                    New-Item -ItemType Junction -Path $junctionPath -Target $external | Out-Null
                    Assert-TestRequiresJunction -Path $junctionPath
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedJunctionChild = (Join-Path $junctionPath "payload.txt").Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
try {
    Assert-NoReparsePointTraversal -RootPath '$escapedFixture' -Path '$escapedJunctionChild'
    throw 'Expected reparse traversal failure.'
} catch {
    `$_.Exception.Message
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $result.StdOut.Trim().ToLowerInvariant() -Message "Reparse traversal failure should mention reparse points."
                } finally {
                    Remove-TempFixture -Path $external
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-DownloadWithHashValidation rejects a junction download directory and existing partial-path junction"
            Body = {
                $fixture = New-BootstrapFixture
                $external = New-TempFixture
                try {
                    $downloadRoot = Join-Path $fixture ".runtime\downloads"
                    $junctionDirectory = Join-Path $fixture ".runtime\junction-downloads"
                    $partialJunction = Join-Path $downloadRoot "payload.zip.partial"
                    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $external -Force | Out-Null
                    New-Item -ItemType Junction -Path $junctionDirectory -Target $external | Out-Null
                    New-Item -ItemType Junction -Path $partialJunction -Target $external | Out-Null

                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedDownloadDir = $junctionDirectory.Replace("'", "''")
                    $escapedPartialDir = $downloadRoot.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Invoke-WebRequest {
    param([string]`$Uri, [string]`$OutFile)
    throw 'invoke-webrequest-reached'
}
`$results = [ordered]@{}
try {
    `$downloadPaths = [pscustomobject]@{
        Directory = '$escapedDownloadDir'
        FinalPath = (Join-Path '$escapedDownloadDir' 'payload.zip')
        PartialPath = (Join-Path '$escapedDownloadDir' 'payload.zip.partial')
    }
    `$null = Invoke-DownloadWithHashValidation -RootPath '$escapedFixture' -Url 'https://example.invalid/payload.zip' -ExpectedSha256 ('A' * 64) -DownloadPaths `$downloadPaths
    `$results.Directory = 'unexpected-success'
} catch {
    `$results.Directory = `$_.Exception.Message
}
try {
    `$downloadPaths = [pscustomobject]@{
        Directory = '$escapedPartialDir'
        FinalPath = (Join-Path '$escapedPartialDir' 'payload.zip')
        PartialPath = (Join-Path '$escapedPartialDir' 'payload.zip.partial')
    }
    `$null = Invoke-DownloadWithHashValidation -RootPath '$escapedFixture' -Url 'https://example.invalid/payload.zip' -ExpectedSha256 ('A' * 64) -DownloadPaths `$downloadPaths
    `$results.Partial = 'unexpected-success'
} catch {
    `$results.Partial = `$_.Exception.Message
}
`$results | ConvertTo-Json -Compress
"@

                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $state.Directory.ToLowerInvariant() -Message "Download directory reparse failure should mention reparse points."
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $state.Partial.ToLowerInvariant() -Message "Partial-path reparse failure should mention reparse points."
                    Assert-False -Condition ($state.Directory -eq "invoke-webrequest-reached") -Message "Reparse validation must reject before download execution."
                    Assert-False -Condition ($state.Partial -eq "invoke-webrequest-reached") -Message "Reparse validation must reject before download execution."
                } finally {
                    Remove-TempFixture -Path $external
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-DownloadWithHashValidation bounds every HTTP attempt"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$script:timeouts = New-Object System.Collections.Generic.List[int]
function Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [string]`$Uri,
        [string]`$OutFile,
        [switch]`$UseBasicParsing,
        [int]`$TimeoutSec = 0
    )
    `$script:timeouts.Add(`$TimeoutSec)
    throw 'bounded-download-fixture'
}
`$paths = [pscustomobject]@{
    Directory = (Join-Path '$escapedFixture' '.runtime\downloads')
    FinalPath = (Join-Path '$escapedFixture' '.runtime\downloads\payload.zip')
    PartialPath = (Join-Path '$escapedFixture' '.runtime\downloads\payload.zip.partial')
}
try {
    `$null = Invoke-DownloadWithHashValidation -RootPath '$escapedFixture' -Url 'https://example.invalid/payload.zip' -ExpectedSha256 ('A' * 64) -DownloadPaths `$paths
} catch {
}
[ordered]@{ Timeouts = @(`$script:timeouts) } | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected @(300, 300, 300) -Actual @($state.Timeouts | ForEach-Object { [int]$_ }) -Message "Each HTTP retry should use the bounded request timeout."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Controlled non-PlanOnly workflow runs the full success orchestration in order"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\doctor.ps1") -Value "Set-Content -LiteralPath '$fixture\doctor-ran.txt' -Value 'doctor'" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\start.ps1") -Value "Set-Content -LiteralPath '$fixture\start-ran.txt' -Value 'start'" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$log = New-Object System.Collections.Generic.List[string]
function Resolve-PythonRuntime {
    param(`$Paths, `$Manifest, [switch]`$SkipDownload, [switch]`$DisablePathProbe)
    `$log.Add('python')
    New-Item -ItemType Directory -Path `$Paths.PythonRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$Paths.PythonRoot 'python.exe') -Value '3.10.11' -Encoding ASCII
    return (Join-Path `$Paths.PythonRoot 'python.exe')
}
function Resolve-NodeRuntime {
    param(`$Paths, `$Manifest, [switch]`$SkipDownload, [switch]`$DisablePathProbe)
    `$log.Add('node')
    New-Item -ItemType Directory -Path `$Paths.NodeRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$Paths.NodeRoot 'node.exe') -Value '24.18.0' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path `$Paths.NodeRoot 'npm.cmd') -Value '@echo npm' -Encoding ASCII
    return [pscustomobject]@{ NodePath = (Join-Path `$Paths.NodeRoot 'node.exe'); NpmPath = (Join-Path `$Paths.NodeRoot 'npm.cmd') }
}
function Install-BackendPythonEnvironment {
    param(`$Paths, `$PythonPath, `$RequestedDevice, `$InitialDevice, `$CpuRequirementsPath, `$GpuRequirementsPath, `$VenvCreator, `$RequirementsInstaller, `$CudaSelfTester)
    `$log.Add('venv:' + `$InitialDevice)
    New-Item -ItemType Directory -Path (Join-Path `$Paths.VenvRoot 'Scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$Paths.VenvRoot 'Scripts\python.exe') -Value 'venv-python' -Encoding ASCII
    return [pscustomobject]@{ VenvPythonPath = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe'); SelectedDevice = `$InitialDevice; RequirementsPath = `$GpuRequirementsPath }
}
function Invoke-NpmInstall {
    param(`$NpmPath, `$FrontendRoot)
    `$log.Add('npm')
}
function Ensure-ModelFiles {
    param(`$Paths, `$Models)
    foreach (`$model in @(`$Models)) {
        `$log.Add('model:' + `$model.filename)
        New-Item -ItemType Directory -Path `$Paths.ModelsRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path `$Paths.ModelsRoot `$model.filename) -Value 'model' -Encoding ASCII
    }
}
`$null = Invoke-BootstrapWorkflow -ProjectRoot '$escapedFixture' -Device 'auto' -ForceConfig -Start -NvidiaSmiAvailable '$true' -OsArchitectureOverride 'x64' -FreeSpaceGbOverride 24
[ordered]@{
    Log = @(`$log)
    EnvExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'backend\.env')
    VenvExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'backend\.venv\Scripts\python.exe')
    ModelCount = @((Get-ChildItem -LiteralPath (Join-Path '$escapedFixture' 'models') -File -ErrorAction SilentlyContinue)).Count
    SqliteParentExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'backend\data') -PathType Container
    DoctorRan = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'doctor-ran.txt')
    StartRan = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'start-ran.txt')
    OutputSecretLeak = `$false
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected @("python","node","venv:gpu","npm","model:tt100k-yolo11s-reference42.pt","model:gtsrb-yolo11n-cls.pt") -Actual @($state.Log) -Message "Full success orchestration order mismatch."
                    Assert-True -Condition $state.EnvExists -Message "Full success orchestration should generate backend/.env."
                    Assert-True -Condition $state.VenvExists -Message "Full success orchestration should leave a venv."
                    Assert-Equal -Expected 2 -Actual $state.ModelCount -Message "Full success orchestration should materialize the two default models."
                    Assert-True -Condition $state.SqliteParentExists -Message "Full success orchestration should create the SQLite parent directory before doctor."
                    Assert-True -Condition $state.DoctorRan -Message "Full success orchestration should run doctor."
                    Assert-True -Condition $state.StartRan -Message "Full success orchestration should run start when requested."
                    Assert-False -Condition $state.OutputSecretLeak -Message "Full success orchestration must not leak secrets to output."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Long-running bootstrap commands use operation-specific bounded timeouts"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $optionalScript = Join-Path $fixture "scripts\optional.ps1"
                    Set-Content -LiteralPath $optionalScript -Value "exit 0" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedOptionalScript = $optionalScript.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
`$calls = New-Object System.Collections.Generic.List[object]
function Invoke-CheckedCommand {
    param(
        [string]`$FilePath,
        [string[]]`$ArgumentList = @(),
        [string]`$WorkingDirectory,
        [int]`$TimeoutSeconds = 30
    )
    `$calls.Add([pscustomobject]@{ Arguments = (`$ArgumentList -join ' '); Timeout = `$TimeoutSeconds })
    [pscustomobject]@{ ExitCode = 0; StdOut = 'ok'; StdErr = '' }
}
Install-PythonRequirements -PythonPath 'python.exe' -RequirementsPath 'requirements.txt' -WorkingDirectory '$escapedFixture'
Invoke-NpmInstall -NpmPath 'npm.cmd' -FrontendRoot '$escapedFixture'
Invoke-OptionalScript -ScriptPath '$escapedOptionalScript' -ProjectRoot '$escapedFixture'
[ordered]@{ Timeouts = @(`$calls | ForEach-Object { `$_.Timeout }) } | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected @(600, 3600, 300, 1800, 300) -Actual @($state.Timeouts | ForEach-Object { [int]$_ }) -Message "Long-running commands should upgrade packaging tools and use bounded operation-specific timeouts."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-BootstrapWorkflow propagates late model failure and does not run doctor or start"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\doctor.ps1") -Value "Set-Content -LiteralPath '$fixture\doctor-ran.txt' -Value 'doctor'" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\start.ps1") -Value "Set-Content -LiteralPath '$fixture\start-ran.txt' -Value 'start'" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $fixture "backend\user-note.txt") -Value "keep-me" -Encoding ASCII
                    $scriptPath = (Get-BootstrapScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$scriptPath'
function Resolve-PythonRuntime {
    param(`$Paths, `$Manifest, [switch]`$SkipDownload, [switch]`$DisablePathProbe)
    New-Item -ItemType Directory -Path `$Paths.PythonRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$Paths.PythonRoot 'python.exe') -Value '3.10.11' -Encoding ASCII
    return (Join-Path `$Paths.PythonRoot 'python.exe')
}
function Resolve-NodeRuntime {
    param(`$Paths, `$Manifest, [switch]`$SkipDownload, [switch]`$DisablePathProbe)
    New-Item -ItemType Directory -Path `$Paths.NodeRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$Paths.NodeRoot 'node.exe') -Value '24.18.0' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path `$Paths.NodeRoot 'npm.cmd') -Value '@echo npm' -Encoding ASCII
    return [pscustomobject]@{ NodePath = (Join-Path `$Paths.NodeRoot 'node.exe'); NpmPath = (Join-Path `$Paths.NodeRoot 'npm.cmd') }
}
function Install-BackendPythonEnvironment {
    param(`$Paths, `$PythonPath, `$RequestedDevice, `$InitialDevice, `$CpuRequirementsPath, `$GpuRequirementsPath, `$VenvCreator, `$RequirementsInstaller, `$CudaSelfTester)
    New-Item -ItemType Directory -Path (Join-Path `$Paths.VenvRoot 'Scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path `$Paths.VenvRoot 'Scripts\python.exe') -Value 'venv-python' -Encoding ASCII
    return [pscustomobject]@{ VenvPythonPath = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe'); SelectedDevice = `$InitialDevice; RequirementsPath = `$GpuRequirementsPath }
}
function Invoke-NpmInstall { param(`$NpmPath, `$FrontendRoot) }
function Ensure-ModelFiles {
    param(`$Paths, `$Models)
    throw 'late-model-failure'
}
try {
    `$null = Invoke-BootstrapWorkflow -ProjectRoot '$escapedFixture' -Device 'auto' -ForceConfig -Start -NvidiaSmiAvailable '$true' -OsArchitectureOverride 'x64' -FreeSpaceGbOverride 24
    throw 'Expected late workflow failure.'
} catch {
    [ordered]@{
        Message = `$_.Exception.Message
        PythonExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' '.runtime\python\python.exe')
        NodeExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' '.runtime\node\node.exe')
        VenvExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'backend\.venv\Scripts\python.exe')
        UserNoteExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'backend\user-note.txt')
        EnvExists = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'backend\.env')
        DoctorRan = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'doctor-ran.txt')
        StartRan = Test-Path -LiteralPath (Join-Path '$escapedFixture' 'start-ran.txt')
    } | ConvertTo-Json -Compress
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Contains -ExpectedSubstring "late-model-failure" -Actual $state.Message -Message "Late workflow failure should propagate the model failure."
                    Assert-True -Condition $state.PythonExists -Message "Late workflow failure should retain the resolved Python runtime."
                    Assert-True -Condition $state.NodeExists -Message "Late workflow failure should retain the resolved Node runtime."
                    Assert-True -Condition $state.VenvExists -Message "Late workflow failure should retain the prepared venv."
                    Assert-True -Condition $state.UserNoteExists -Message "Late workflow failure should not remove unrelated user-owned artifacts."
                    Assert-False -Condition $state.EnvExists -Message "Late workflow failure before env generation should not create backend/.env."
                    Assert-False -Condition $state.DoctorRan -Message "Late workflow failure should not run doctor."
                    Assert-False -Condition $state.StartRan -Message "Late workflow failure should not run start."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop script AST parses cleanly, exposes the expected parameters, and stays idle when dot-sourced"
            Body = {
                $stopScriptPath = Get-StopScriptPath
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($stopScriptPath, [ref]$tokens, [ref]$parseErrors)

                Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "Stop script parse errors were found."

                $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                foreach ($parameterName in @("ProjectRoot", "TimeoutSeconds")) {
                    Assert-True -Condition ($parameterNames -contains $parameterName) -Message "Missing required stop parameter '$parameterName'."
                }
                Assert-False -Condition ($ast.ParamBlock.Extent.Text.Contains('Join-Path $PSScriptRoot')) -Message "Stop must resolve its default project root after parameter binding."

                $escapedStopPath = $stopScriptPath.Replace("'", "''")
                $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$escapedStopPath'
'dot-sourced'
"@
                $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory (Split-Path -Parent $stopScriptPath)
                Assert-Equal -Expected "dot-sourced" -Actual $result.StdOut.Trim() -Message "Stop script should not auto-run when dot-sourced."
                Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Stop script emitted unexpected stderr when dot-sourced."
            }
        },
        @{
            Name = "Stop resolves an empty project root from the script directory"
            Body = {
                $fixture = New-TempFixture
                try {
                    $stopScriptPath = (Get-StopScriptPath).Replace("'", "''")
                    $expectedRoot = (Split-Path -Parent (Split-Path -Parent (Get-StopScriptPath))).Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$stopScriptPath'
Resolve-StopProjectRoot -ProjectRoot ''
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Equal -Expected $expectedRoot -Actual $result.StdOut.Trim() -Message "Stop should resolve its default root relative to stop.ps1, not the caller working directory."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop succeeds when backend and frontend state records are absent"
            Body = {
                $fixture = New-StopFixture
                try {
                    $result = Invoke-StopScriptProcess -ProjectRoot $fixture
                    Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "Stop should succeed when no state records exist."
                    Assert-Contains -ExpectedSubstring "backend" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop output should mention backend state."
                    Assert-Contains -ExpectedSubstring "frontend" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop output should mention frontend state."
                    Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Stop should keep stderr empty when records are absent."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop refuses a malformed backend state record and preserves it"
            Body = {
                $fixture = New-StopFixture
                try {
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record '{"pid":'
                    $before = Get-Content -LiteralPath $path -Raw
                    $result = Invoke-StopScriptProcess -ProjectRoot $fixture

                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Stop should refuse malformed backend state."
                    Assert-Contains -ExpectedSubstring "backend" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop refusal should mention backend."
                    Assert-Contains -ExpectedSubstring "invalid" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop refusal should report invalid state."
                    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Malformed backend record must be preserved."
                    Assert-Equal -Expected $before -Actual (Get-Content -LiteralPath $path -Raw) -Message "Malformed backend record content changed."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop refuses a missing or unsupported backend record schemaVersion and preserves the record"
            Body = {
                $cases = @(
                    [pscustomobject]@{
                        Name = "missing"
                        Overrides = @{}
                        RemoveSchema = $true
                    },
                    [pscustomobject]@{
                        Name = "unsupported"
                        Overrides = @{ schemaVersion = 2 }
                        RemoveSchema = $false
                    }
                )

                foreach ($case in $cases) {
                    $fixture = New-StopFixture
                    try {
                        $record = [ordered]@{
                            schemaVersion = 1
                            pid = (Get-NonexistentProcessId)
                            executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                            startTimeUtc = [datetime]::UtcNow.ToString("o")
                            commandLine = "$fixture project-role-backend"
                            projectRoot = $fixture
                            role = "backend"
                        }
                        foreach ($entry in $case.Overrides.GetEnumerator()) {
                            $record[$entry.Key] = $entry.Value
                        }
                        if ($case.RemoveSchema) {
                            $record.Remove("schemaVersion")
                        }
                        $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record
                        $before = Get-Content -LiteralPath $path -Raw

                        $result = Invoke-StopScriptProcess -ProjectRoot $fixture
                        Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Stop should refuse the $($case.Name) schemaVersion case."
                        Assert-Contains -ExpectedSubstring "backend" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop should mention backend for the $($case.Name) schemaVersion case."
                        Assert-Contains -ExpectedSubstring "invalid" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop should report invalid state for the $($case.Name) schemaVersion case."
                        Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Stop should preserve the record for the $($case.Name) schemaVersion case."
                        Assert-Equal -Expected $before -Actual (Get-Content -LiteralPath $path -Raw) -Message "Stop changed the record for the $($case.Name) schemaVersion case."
                    } finally {
                        Remove-TempFixture -Path $fixture
                    }
                }
            }
        },
        @{
            Name = "Stop refuses non-UTC startTimeUtc encodings and preserves the backend record"
            Body = {
                $cases = @(
                    [pscustomobject]@{
                        Name = "local"
                        Value = ([datetime]::SpecifyKind([datetime]::UtcNow.ToLocalTime(), [System.DateTimeKind]::Local)).ToString("o")
                    },
                    [pscustomobject]@{
                        Name = "no-offset"
                        Value = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffff")
                    },
                    [pscustomobject]@{
                        Name = "plus-08"
                        Value = ([datetimeoffset]::Parse("2026-07-15T12:34:56.1234567+08:00", [System.Globalization.CultureInfo]::InvariantCulture)).ToString("o")
                    }
                )

                foreach ($case in $cases) {
                    $fixture = New-StopFixture
                    try {
                        $record = [ordered]@{
                            schemaVersion = 1
                            pid = (Get-NonexistentProcessId)
                            executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                            startTimeUtc = $case.Value
                            commandLine = "$fixture project-role-backend"
                            projectRoot = $fixture
                            role = "backend"
                        }
                        $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record
                        $before = Get-Content -LiteralPath $path -Raw

                        $result = Invoke-StopScriptProcess -ProjectRoot $fixture
                        Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Stop should refuse the $($case.Name) startTimeUtc encoding."
                        Assert-Contains -ExpectedSubstring "backend" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop should mention backend for the $($case.Name) startTimeUtc encoding."
                        Assert-Contains -ExpectedSubstring "invalid" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop should report invalid state for the $($case.Name) startTimeUtc encoding."
                        Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Stop should preserve the record for the $($case.Name) startTimeUtc encoding."
                        Assert-Equal -Expected $before -Actual (Get-Content -LiteralPath $path -Raw) -Message "Stop changed the record for the $($case.Name) startTimeUtc encoding."
                    } finally {
                        Remove-TempFixture -Path $fixture
                    }
                }
            }
        },
        @{
            Name = "Stop removes a stale backend state record when the PID no longer exists"
            Body = {
                $fixture = New-StopFixture
                try {
                    $stalePid = Get-NonexistentProcessId
                    $record = [ordered]@{
                        schemaVersion = 1
                        pid = $stalePid
                        executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                        startTimeUtc = [datetime]::UtcNow.ToString("o")
                        commandLine = "$fixture project-role-backend"
                        projectRoot = $fixture
                        role = "backend"
                    }
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record

                    $result = Invoke-StopScriptProcess -ProjectRoot $fixture
                    Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "Stop should treat a stale backend record as success."
                    Assert-False -Condition (Test-Path -LiteralPath $path) -Message "Stale backend record should be removed."
                    Assert-Contains -ExpectedSubstring "stale" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop should report stale backend cleanup."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop refuses a black-box backend stop when the live child command line is unavailable"
            Body = {
                $fixture = New-StopFixture
                $child = $null
                try {
                    $child = Start-StopTestChildProcess -ProjectRoot $fixture -Role backend -Secret "SENTINEL-STOP-SUCCESS"
                    $record = [ordered]@{
                        schemaVersion = 1
                        pid = [int]$child.Identity.Pid
                        executablePath = [string]$child.Identity.ExecutablePath
                        startTimeUtc = ([datetime]$child.Identity.StartTimeUtc).ToUniversalTime().ToString("o")
                        commandLine = [string]$child.IntendedCommandLine
                        projectRoot = [string]$fixture
                        role = "backend"
                    }
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record

                    $result = Invoke-StopScriptProcess -ProjectRoot $fixture -ArgumentList @("-TimeoutSeconds", "5")
                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Stop should refuse the black-box backend stop when live command line lookup is unavailable."
                    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Black-box backend refusal should preserve the record."
                    Assert-Contains -ExpectedSubstring "identity mismatch" -Actual $result.StdOut.ToLowerInvariant() -Message "Black-box backend refusal should report identity mismatch."
                    Assert-False -Condition (($result.StdOut + $result.StdErr).Contains("SENTINEL-STOP-SUCCESS")) -Message "Stop output leaked the backend child secret."
                    Assert-True -Condition ([bool](Get-Process -Id $child.Process.Id -ErrorAction SilentlyContinue)) -Message "Black-box backend refusal should leave the child process running."
                } finally {
                    Stop-StopTestChildProcess -Child $child
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Injected stop success kills a matching backend child via handle wait and removes its state record"
            Body = {
                $fixture = New-StopFixture
                $child = $null
                try {
                    $child = Start-StopTestChildProcess -ProjectRoot $fixture -Role backend -Secret "SENTINEL-STOP-INJECTED"
                    $actualIdentity = New-StopSyntheticActualIdentity -Child $child
                    $record = New-StopRecordFromSyntheticIdentity -Child $child -ActualIdentity $actualIdentity
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record
                    $stopScriptPath = (Get-StopScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedExecutablePath = ([string]$actualIdentity.ExecutablePath).Replace("'", "''")
                    $escapedCommandLine = ([string]$actualIdentity.CommandLine).Replace("'", "''")
                    $startTimeText = ([datetime]$actualIdentity.StartTimeUtc).ToString("o")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$stopScriptPath'
`$actualIdentity = [pscustomobject]@{
    Pid = $($actualIdentity.Pid)
    ExecutablePath = '$escapedExecutablePath'
    StartTimeUtc = [datetime]::Parse('$startTimeText', [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    CommandLine = '$escapedCommandLine'
}
`$identityProvider = { param(`$ProcessHandle) `$actualIdentity }.GetNewClosure()
`$identityComparer = {
    param(`$RecordedIdentity, `$ProcessHandle, `$ActualIdentity)
    if ([int]`$RecordedIdentity.Pid -ne [int]`$ActualIdentity.Pid) { return `$false }
    if (-not ([System.IO.Path]::GetFullPath([string]`$RecordedIdentity.ExecutablePath)).Equals([System.IO.Path]::GetFullPath([string]`$ActualIdentity.ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) { return `$false }
    `$recordedStart = [datetime]::Parse([string]`$RecordedIdentity.StartTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    `$actualStart = ([datetime]`$ActualIdentity.StartTimeUtc).ToUniversalTime()
    if (`$recordedStart -ne `$actualStart) { return `$false }
    return ([string]`$RecordedIdentity.CommandLine).Equals([string]`$ActualIdentity.CommandLine, [System.StringComparison]::Ordinal)
}.GetNewClosure()
`$result = Stop-ManagedRole -RootPath '$escapedFixture' -Role backend -TimeoutSeconds 5 -IdentityProvider `$identityProvider -IdentityComparer `$identityComparer
[ordered]@{
    Success = [bool]`$result.Success
    Message = [string]`$result.Message
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-True -Condition ([bool]$state.Success) -Message "Injected stop success should terminate the matching backend child."
                    Assert-False -Condition (Test-Path -LiteralPath $path) -Message "Injected stop success should remove the record."
                    Assert-Contains -ExpectedSubstring "stopped" -Actual ([string]$state.Message).ToLowerInvariant() -Message "Injected stop success should report the backend stop."
                    Start-Sleep -Milliseconds 500
                    Assert-False -Condition ([bool](Get-Process -Id $child.Process.Id -ErrorAction SilentlyContinue)) -Message "Injected stop success should leave the child process stopped."
                } finally {
                    Stop-StopTestChildProcess -Child $child
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop refuses mismatched executable start time command line or project root and preserves the backend child"
            Body = {
                $cases = @(
                    [pscustomobject]@{
                        Name = "executable"
                        Overrides = @{ executablePath = "C:\Windows\System32\cmd.exe" }
                        Expected = "identity mismatch"
                    },
                    [pscustomobject]@{
                        Name = "start-time"
                        Overrides = @{ startTimeUtc = [datetime]::UtcNow.AddMinutes(-5).ToString("o") }
                        Expected = "identity mismatch"
                    },
                    [pscustomobject]@{
                        Name = "command-line"
                        Overrides = @{ commandLine = "powershell.exe -NoProfile project-role-backend wrong-root SENTINEL-STOP-MISMATCH" }
                        Expected = "identity mismatch"
                    },
                    [pscustomobject]@{
                        Name = "project-root"
                        Overrides = @{ projectRoot = (Join-Path $env:TEMP "wrong-root") }
                        Expected = "project root"
                    }
                )

                foreach ($case in $cases) {
                    $fixture = New-StopFixture
                    $child = $null
                    try {
                        $child = Start-StopTestChildProcess -ProjectRoot $fixture -Role backend -Secret "SENTINEL-STOP-MISMATCH"
                        $actualOverrides = if ($case.Name -eq "project-root") { $null } else { $case.Overrides }
                        $recordOverrides = if ($case.Name -eq "project-root") { $case.Overrides } else { $null }
                        $actualIdentity = New-StopSyntheticActualIdentity -Child $child -Overrides $actualOverrides
                        $record = New-StopRecordFromSyntheticIdentity -Child $child -ActualIdentity (New-StopSyntheticActualIdentity -Child $child) -Overrides $recordOverrides
                        $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record
                        $before = Get-Content -LiteralPath $path -Raw
                        $stopScriptPath = (Get-StopScriptPath).Replace("'", "''")
                        $escapedFixture = $fixture.Replace("'", "''")
                        $escapedExecutablePath = ([string]$actualIdentity.ExecutablePath).Replace("'", "''")
                        $escapedCommandLine = ([string]$actualIdentity.CommandLine).Replace("'", "''")
                        $startTimeText = ([datetime]$actualIdentity.StartTimeUtc).ToString("o")
                        $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$stopScriptPath'
`$actualIdentity = [pscustomobject]@{
    Pid = $($actualIdentity.Pid)
    ExecutablePath = '$escapedExecutablePath'
    StartTimeUtc = [datetime]::Parse('$startTimeText', [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    CommandLine = '$escapedCommandLine'
}
`$identityProvider = { param(`$ProcessId) `$actualIdentity }.GetNewClosure()
`$identityComparer = {
    param(`$RecordedIdentity, `$ProcessId)
    if ([int]`$RecordedIdentity.Pid -ne [int]`$actualIdentity.Pid) { return `$false }
    if (-not ([System.IO.Path]::GetFullPath([string]`$RecordedIdentity.ExecutablePath)).Equals([System.IO.Path]::GetFullPath([string]`$actualIdentity.ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) { return `$false }
    `$recordedStart = [datetime]::Parse([string]`$RecordedIdentity.StartTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    `$actualStart = ([datetime]`$actualIdentity.StartTimeUtc).ToUniversalTime()
    if (`$recordedStart -ne `$actualStart) { return `$false }
    return ([string]`$RecordedIdentity.CommandLine).Equals([string]`$actualIdentity.CommandLine, [System.StringComparison]::Ordinal)
}.GetNewClosure()
try {
    `$result = Stop-ManagedRole -RootPath '$escapedFixture' -Role backend -TimeoutSeconds 5 -IdentityProvider `$identityProvider -IdentityComparer `$identityComparer
    [ordered]@{
        Success = [bool]`$result.Success
        Message = [string]`$result.Message
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        Success = `$false
        Message = [string]`$_.Exception.Message
    } | ConvertTo-Json -Compress
}
"@
                        $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                        $state = $result.StdOut | ConvertFrom-Json
                        Assert-False -Condition ([bool]$state.Success) -Message "Stop should refuse the $($case.Name) mismatch case."
                        Assert-Contains -ExpectedSubstring "backend" -Actual ([string]$state.Message).ToLowerInvariant() -Message "Stop refusal should mention backend for the $($case.Name) mismatch case."
                        Assert-Contains -ExpectedSubstring $case.Expected -Actual ([string]$state.Message).ToLowerInvariant() -Message "Stop refusal message mismatch for the $($case.Name) case."
                        Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Stop should preserve the record for the $($case.Name) mismatch case."
                        Assert-Equal -Expected $before -Actual (Get-Content -LiteralPath $path -Raw) -Message "Stop changed the record for the $($case.Name) mismatch case."
                        Assert-True -Condition ([bool](Get-Process -Id $child.Process.Id -ErrorAction SilentlyContinue)) -Message "Stop terminated the backend child during the $($case.Name) mismatch case."
                        Assert-False -Condition ((([string]$result.StdOut) + ([string]$result.StdErr)).Contains("SENTINEL-STOP-MISMATCH")) -Message "Stop output leaked a secret during the $($case.Name) mismatch case."
                    } finally {
                        Stop-StopTestChildProcess -Child $child
                        Remove-TempFixture -Path $fixture
                    }
                }
            }
        },
        @{
            Name = "Injected stop refuses a start-time change before kill and does not call Kill"
            Body = {
                $fixture = New-StopFixture
                try {
                    . (Get-StopScriptPath)
                    $statePath = Get-StopFixtureStatePath -ProjectRoot $fixture -Role backend
                    $record = [ordered]@{
                        schemaVersion = 1
                        pid = 424242
                        executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                        startTimeUtc = [datetime]::UtcNow.ToString("o")
                        commandLine = "$fixture project-role-backend"
                        projectRoot = $fixture
                        role = "backend"
                    }
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record
                    $startA = [datetime]::UtcNow
                    $startB = $startA.AddSeconds(1)
                    $killed = $false
                    $waitCalled = $false
                    $fakeProcess = New-Object psobject
                    Add-Member -InputObject $fakeProcess -NotePropertyName Id -NotePropertyValue 424242
                    Add-Member -InputObject $fakeProcess -NotePropertyName HasExited -NotePropertyValue $false
                    Add-Member -InputObject $fakeProcess -NotePropertyName StartTime -NotePropertyValue $startA
                    Add-Member -InputObject $fakeProcess -MemberType ScriptMethod -Name Refresh -Value {
                        $this.StartTime = $startB
                    }.GetNewClosure()
                    Add-Member -InputObject $fakeProcess -MemberType ScriptMethod -Name Kill -Value {
                        $script:killed = $true
                    }.GetNewClosure()
                    Add-Member -InputObject $fakeProcess -MemberType ScriptMethod -Name WaitForExit -Value {
                        param([int]$TimeoutMilliseconds)
                        $script:waitCalled = $true
                        return $true
                    }.GetNewClosure()
                    $processProvider = { param($ProcessId) $fakeProcess }.GetNewClosure()
                    $identityProvider = {
                        param($ProcessHandle)
                        [pscustomobject]@{
                            Pid = 424242
                            ExecutablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                            StartTimeUtc = $startA.ToUniversalTime()
                            CommandLine = "$fixture project-role-backend"
                        }
                    }.GetNewClosure()
                    $identityComparer = { param($RecordedIdentity, $ProcessHandle, $ActualIdentity) return $true }

                    $result = Stop-ManagedRole -RootPath $fixture -Role backend -TimeoutSeconds 5 -ProcessProvider $processProvider -IdentityProvider $identityProvider -IdentityComparer $identityComparer
                    Assert-False -Condition ([bool]$result.Success) -Message "Stop should refuse a changed start time before kill."
                    Assert-Contains -ExpectedSubstring "identity mismatch" -Actual $result.Message.ToLowerInvariant() -Message "Start-time change refusal should report identity mismatch."
                    Assert-False -Condition $killed -Message "Kill must not be called when start time changes before kill."
                    Assert-False -Condition $waitCalled -Message "WaitForExit must not be called when start time changes before kill."
                    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Start-time change refusal should preserve the record."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop refuses a backend state record routed through a junction descendant"
            Body = {
                $fixture = New-BootstrapFixture
                $external = New-TempFixture
                try {
                    $runtimeRoot = Join-Path $fixture ".runtime"
                    $stateLink = Join-Path $runtimeRoot "state"
                    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $external -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $external "backend.json") -Value "{}" -Encoding ASCII
                    New-Item -ItemType Junction -Path $stateLink -Target $external | Out-Null
                    Assert-TestRequiresJunction -Path $stateLink

                    $result = Invoke-StopScriptProcess -ProjectRoot $fixture
                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Stop should refuse reparse-routed backend state."
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $result.StdOut.ToLowerInvariant() -Message "Stop reparse refusal should mention reparse points."
                    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $external "backend.json") -PathType Leaf) -Message "Stop should preserve the external backend record."
                } finally {
                    Remove-TempFixture -Path $external
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop rename-then-delete preserves the original record when rename fails"
            Body = {
                $fixture = New-StopFixture
                try {
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record ([ordered]@{
                        schemaVersion = 1
                        pid = (Get-NonexistentProcessId)
                        executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                        startTimeUtc = [datetime]::UtcNow.ToString("o")
                        commandLine = "$fixture project-role-backend"
                        projectRoot = $fixture
                        role = "backend"
                    })
                    $before = Get-Content -LiteralPath $path -Raw
                    $stopScriptPath = (Get-StopScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedPath = $path.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$stopScriptPath'
function Move-Item {
    param()
    throw 'rename-failed'
}
try {
    Remove-StopStateRecord -RootPath '$escapedFixture' -StatePath '$escapedPath'
    throw 'Expected rename failure.'
} catch {
    `$_.Exception.Message
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Contains -ExpectedSubstring "rename-failed" -Actual $result.StdOut -Message "Rename failure should surface the move failure."
                    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Rename failure should preserve the original record."
                    Assert-Equal -Expected $before -Actual (Get-Content -LiteralPath $path -Raw) -Message "Rename failure changed the original record."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop rename-then-delete refuses a quarantine junction leaf and preserves the original record"
            Body = {
                $fixture = New-StopFixture
                $external = New-TempFixture
                try {
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record ([ordered]@{
                        schemaVersion = 1
                        pid = (Get-NonexistentProcessId)
                        executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                        startTimeUtc = [datetime]::UtcNow.ToString("o")
                        commandLine = "$fixture project-role-backend"
                        projectRoot = $fixture
                        role = "backend"
                    })
                    $stateDirectory = Split-Path -Parent $path
                    $quarantineTarget = Join-Path $stateDirectory "backend.quarantine-fixed.json"
                    New-Item -ItemType Directory -Path $external -Force | Out-Null
                    New-Item -ItemType Junction -Path $quarantineTarget -Target $external | Out-Null
                    Assert-TestRequiresJunction -Path $quarantineTarget
                    $stopScriptPath = (Get-StopScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedPath = $path.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$stopScriptPath'
`$provider = { param(`$StateDirectoryPath, `$StateLeaf) return (Join-Path `$StateDirectoryPath 'backend.quarantine-fixed.json') }
try {
    Remove-StopStateRecord -RootPath '$escapedFixture' -StatePath '$escapedPath' -QuarantinePathProvider `$provider
    throw 'Expected quarantine reparse refusal.'
} catch {
    `$_.Exception.Message
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $result.StdOut.ToLowerInvariant() -Message "Quarantine junction refusal should mention reparse points."
                    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Quarantine junction refusal should preserve the original record."
                } finally {
                    Remove-TempFixture -Path $external
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Stop remains idempotent after an injected successful backend stop"
            Body = {
                $fixture = New-StopFixture
                $child = $null
                try {
                    $child = Start-StopTestChildProcess -ProjectRoot $fixture -Role backend -Secret "SENTINEL-STOP-IDEMPOTENT"
                    $actualIdentity = New-StopSyntheticActualIdentity -Child $child
                    $record = New-StopRecordFromSyntheticIdentity -Child $child -ActualIdentity $actualIdentity
                    $path = Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $record
                    $stopScriptPath = (Get-StopScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $escapedExecutablePath = ([string]$actualIdentity.ExecutablePath).Replace("'", "''")
                    $escapedCommandLine = ([string]$actualIdentity.CommandLine).Replace("'", "''")
                    $startTimeText = ([datetime]$actualIdentity.StartTimeUtc).ToString("o")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$stopScriptPath'
`$actualIdentity = [pscustomobject]@{
    Pid = $($actualIdentity.Pid)
    ExecutablePath = '$escapedExecutablePath'
    StartTimeUtc = [datetime]::Parse('$startTimeText', [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    CommandLine = '$escapedCommandLine'
}
`$identityProvider = { param(`$ProcessHandle) `$actualIdentity }.GetNewClosure()
`$identityComparer = {
    param(`$RecordedIdentity, `$ProcessHandle, `$ActualIdentity)
    if ([int]`$RecordedIdentity.Pid -ne [int]`$ActualIdentity.Pid) { return `$false }
    if (-not ([System.IO.Path]::GetFullPath([string]`$RecordedIdentity.ExecutablePath)).Equals([System.IO.Path]::GetFullPath([string]`$ActualIdentity.ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) { return `$false }
    `$recordedStart = [datetime]::Parse([string]`$RecordedIdentity.StartTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    `$actualStart = ([datetime]`$ActualIdentity.StartTimeUtc).ToUniversalTime()
    if (`$recordedStart -ne `$actualStart) { return `$false }
    return ([string]`$RecordedIdentity.CommandLine).Equals([string]`$ActualIdentity.CommandLine, [System.StringComparison]::Ordinal)
}.GetNewClosure()
`$first = Stop-ManagedRole -RootPath '$escapedFixture' -Role backend -TimeoutSeconds 5 -IdentityProvider `$identityProvider -IdentityComparer `$identityComparer
[ordered]@{
    Success = [bool]`$first.Success
    Message = [string]`$first.Message
} | ConvertTo-Json -Compress
"@
                    $first = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $firstState = $first.StdOut | ConvertFrom-Json
                    Assert-True -Condition ([bool]$firstState.Success) -Message "Injected first stop should succeed."
                    Assert-False -Condition (Test-Path -LiteralPath $path) -Message "First stop should remove the backend record."

                    $second = Invoke-StopScriptProcess -ProjectRoot $fixture -ArgumentList @("-TimeoutSeconds", "5")
                    Assert-Equal -Expected 0 -Actual $second.ExitCode -Message "Second stop should also succeed."
                    Assert-Contains -ExpectedSubstring "backend" -Actual $second.StdOut.ToLowerInvariant() -Message "Second stop output should mention backend."
                    Assert-Contains -ExpectedSubstring "no state record" -Actual $second.StdOut.ToLowerInvariant() -Message "Second stop should report the missing backend record."
                    Assert-False -Condition (($first.StdOut + $first.StdErr + $second.StdOut + $second.StdErr).Contains("SENTINEL-STOP-IDEMPOTENT")) -Message "Idempotent stop output leaked a secret."
                } finally {
                    Stop-StopTestChildProcess -Child $child
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: script AST parses cleanly, exposes expected parameters, and dot-sources idly"
            Body = {
                $startScriptPath = Get-StartScriptPath
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($startScriptPath, [ref]$tokens, [ref]$parseErrors)

                Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "Start script parse errors were found."

                $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                Assert-Equal -Expected @("ProjectRoot", "BackendPort", "FrontendPort", "TimeoutSeconds") -Actual $parameterNames -Message "Start parameters mismatch."

                $paramText = $ast.ParamBlock.Extent.Text
                Assert-False -Condition ($paramText.Contains('Join-Path $PSScriptRoot')) -Message "Start must resolve its default project root after parameter binding."
                Assert-Contains -ExpectedSubstring '[int]$BackendPort = 8000' -Actual $paramText -Message "Start BackendPort default mismatch."
                Assert-Contains -ExpectedSubstring '[int]$FrontendPort = 5173' -Actual $paramText -Message "Start FrontendPort default mismatch."
                Assert-Contains -ExpectedSubstring '[int]$TimeoutSeconds = 90' -Actual $paramText -Message "Start TimeoutSeconds default mismatch."
                Assert-False -Condition ($paramText.Contains("ValidateRange")) -Message "Start parameter validation must occur in direct flow, not param attributes."

                $startRoot = Split-Path -Parent (Split-Path -Parent $startScriptPath)
                . $startScriptPath -ProjectRoot $startRoot
                try {
                    Assert-StartDirectInputs -BackendPort 8123 -FrontendPort 8123 -TimeoutSeconds 30
                    throw "Expected equal-port rejection."
                } catch {
                    Assert-Contains -ExpectedSubstring "different" -Actual $_.Exception.Message.ToLowerInvariant() -Message "Backend and frontend ports must differ."
                }

                $frontendCode = New-StartFrontendCode -ProjectRoot "C:\project root" -Port 5123 -BackendPort 8123
                Assert-False -Condition $frontendCode.Contains("configFile: false") -Message "Frontend launch must load vite.config.js."
                Assert-Contains -ExpectedSubstring "configLoader: 'native'" -Actual $frontendCode -Message "Frontend launch should load the ESM config without an esbuild child process."
                Assert-Contains -ExpectedSubstring "strictPort: true" -Actual $frontendCode -Message "Frontend launch must refuse fallback ports."
                Assert-Contains -ExpectedSubstring "open: false" -Actual $frontendCode -Message "Frontend launch must not open a browser."
                Assert-Contains -ExpectedSubstring "http://127.0.0.1:8123" -Actual $frontendCode -Message "Frontend proxy must target the selected backend port."

                $fixture = New-StartFixture
                try {
                    $startScriptLiteral = $startScriptPath.Replace("'", "''")
                    $fixtureLiteral = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$startScriptLiteral'
[ordered]@{
    HasInvokeStartMain = [bool](Get-Command Invoke-StartMain -ErrorAction SilentlyContinue)
    StdOut = ''
    StateExists = Test-Path -LiteralPath (Join-Path '$fixtureLiteral' '.runtime\state')
    LogsExists = Test-Path -LiteralPath (Join-Path '$fixtureLiteral' '.runtime\logs')
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-True -Condition ([bool]$state.HasInvokeStartMain) -Message "Dot-sourcing start.ps1 should expose Invoke-StartMain."
                    Assert-False -Condition ([bool]$state.StateExists) -Message "Dot-sourcing start.ps1 must not create the state directory."
                    Assert-False -Condition ([bool]$state.LogsExists) -Message "Dot-sourcing start.ps1 must not create the logs directory."
                    Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Dot-sourcing start.ps1 should keep stderr empty."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: direct invocation resolves the default project root after parameter binding"
            Body = {
                $result = Invoke-StartScriptProcess -ArgumentList @(
                    "-BackendPort", "18123",
                    "-FrontendPort", "18123",
                    "-TimeoutSeconds", "5"
                )

                Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Equal ports should make direct start fail safely."
                Assert-Contains -ExpectedSubstring "different" -Actual ($result.StdOut + $result.StdErr).ToLowerInvariant() -Message "Direct start should reach explicit port validation without a ProjectRoot argument."
                Assert-False -Condition (($result.StdOut + $result.StdErr).Contains("Cannot bind argument to parameter 'Path'")) -Message "Direct start must not evaluate Join-Path against an empty PSScriptRoot during parameter binding."
            }
        },
        @{
            Name = "START: backend launch spec owns the base Python process"
            Body = {
                $fixture = New-StartFixture
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment
                    $paths = Resolve-StartPaths -RootPath $fixture
                    $basePythonPath = Get-StartBasePythonPath -RootPath $fixture -VenvPythonPath $paths.PythonPath
                    $paths | Add-Member -NotePropertyName BasePythonPath -NotePropertyValue $basePythonPath

                    $spec = New-StartLaunchSpec -RootPath $fixture -Paths $paths -Role backend -Port 18124 -BackendPort 18124
                    Assert-Equal -Expected (Join-Path $fixture ".runtime\python\python.exe") -Actual $spec.FilePath -Message "Backend should launch the base Python process directly."
                    Assert-Equal -Expected $paths.PythonPath -Actual ([string]$spec.EnvironmentVariables["__PYVENV_LAUNCHER__"]) -Message "Backend launch should preserve virtual-environment semantics for the child."
                    Assert-Contains -ExpectedSubstring ([string]$spec.FilePath) -Actual ([string]$spec.IntendedCommandLine) -Message "Recorded command line should use the owned base Python executable."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: managed launcher scopes child environment overrides"
            Body = {
                $fixture = New-TempFixture
                $launch = $null
                $variableName = "PROJECT1_START_ENV_FIXTURE"
                $previousValue = [Environment]::GetEnvironmentVariable($variableName, "Process")
                try {
                    $stdoutPath = Join-Path $fixture "environment.stdout.log"
                    $stderrPath = Join-Path $fixture "environment.stderr.log"
                    [Environment]::SetEnvironmentVariable($variableName, "parent-value", "Process")
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $launch = Start-ManagedProcess -LaunchSpec ([pscustomobject]@{
                        FilePath = (Join-Path $PSHOME "powershell.exe")
                        ArgumentList = @("-NoProfile", "-Command", "Write-Output `$env:$variableName")
                        WorkingDirectory = $fixture
                        StdOutLogPath = $stdoutPath
                        StdErrLogPath = $stderrPath
                        IntendedCommandLine = "environment-probe"
                        EnvironmentVariables = @{ $variableName = "child-value" }
                    })
                    Assert-True -Condition $launch.Process.WaitForExit(10000) -Message "Environment probe child should exit."
                    $launch.Process.Refresh()

                    Assert-Equal -Expected "child-value" -Actual ([System.IO.File]::ReadAllText($stdoutPath).Trim()) -Message "Managed child should receive its scoped environment override."
                    Assert-Equal -Expected "parent-value" -Actual ([Environment]::GetEnvironmentVariable($variableName, "Process")) -Message "Managed launch should restore the parent process environment."
                } finally {
                    if ($null -ne $launch) {
                        try { $launch.Process.Dispose() } catch {}
                    }
                    [Environment]::SetEnvironmentVariable($variableName, $previousValue, "Process")
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: managed launcher redirects logs without parent event jobs"
            Body = {
                $fixture = New-StartFixture
                $launch = $null
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $logsRoot = Join-Path $fixture ".runtime\logs"
                    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
                    $stdoutPath = Join-Path $logsRoot "launcher.stdout.log"
                    $stderrPath = Join-Path $logsRoot "launcher.stderr.log"
                    $marker = "START-LAUNCHER-REDIRECT-MARKER"
                    $childCode = "Write-Output '$marker'; Start-Sleep -Seconds 10"
                    $environmentBefore = [System.Environment]::GetEnvironmentVariables()
                    $pathSnapshotBefore = @($environmentBefore.Keys | Where-Object {
                            ([string]$_).Equals("PATH", [System.StringComparison]::OrdinalIgnoreCase)
                        } | ForEach-Object { "$_=$($environmentBefore[$_])" } | Sort-Object)
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $launch = Start-ManagedProcess -LaunchSpec ([pscustomobject]@{
                        FilePath = (Join-Path $PSHOME "powershell.exe")
                        ArgumentList = @("-NoProfile", "-Command", $childCode)
                        WorkingDirectory = $fixture
                        StdOutLogPath = $stdoutPath
                        StdErrLogPath = $stderrPath
                        IntendedCommandLine = "launcher-probe"
                    })
                    $stopwatch.Stop()

                    Assert-True -Condition ($stopwatch.Elapsed.TotalSeconds -lt 3) -Message "Managed launch should return without waiting for the child."
                    Assert-Equal -Expected "Project1.Windows.OwnedProcess" -Actual $launch.Process.GetType().FullName -Message "Managed launch must retain the exact CreateProcess handle instead of reopening by PID."
                    Assert-True -Condition ($null -eq $launch.PSObject.Properties["StdOutRegistration"]) -Message "Managed launch must not retain a parent stdout event subscription."
                    Assert-True -Condition ($null -eq $launch.PSObject.Properties["StdErrRegistration"]) -Message "Managed launch must not retain a parent stderr event subscription."
                    Assert-True -Condition ($null -eq $launch.PSObject.Properties["StdOutWriter"]) -Message "Managed launch must not retain a parent stdout writer."
                    Assert-True -Condition ($null -eq $launch.PSObject.Properties["StdErrWriter"]) -Message "Managed launch must not retain a parent stderr writer."
                    $environmentAfter = [System.Environment]::GetEnvironmentVariables()
                    $pathSnapshotAfter = @($environmentAfter.Keys | Where-Object {
                            ([string]$_).Equals("PATH", [System.StringComparison]::OrdinalIgnoreCase)
                        } | ForEach-Object { "$_=$($environmentAfter[$_])" } | Sort-Object)
                    Assert-Equal -Expected $pathSnapshotBefore -Actual $pathSnapshotAfter -Message "Managed launch must not mutate the caller PATH environment."

                    $deadline = [datetime]::UtcNow.AddSeconds(3)
                    $logContent = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
                    while ([datetime]::UtcNow -lt $deadline -and -not ($logContent -like "*$marker*")) {
                        Start-Sleep -Milliseconds 100
                        $logContent = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
                    }
                    Assert-Contains -ExpectedSubstring $marker -Actual (Get-Content -LiteralPath $stdoutPath -Raw) -Message "Managed launch should redirect stdout directly to its log."
                } finally {
                    if ($null -ne $launch) {
                        Stop-StartedProcessHandle -Started $launch -TimeoutSeconds 5
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: detached child keeps logging after starter process exits"
            Body = {
                $fixture = New-StartFixture
                $parent = $null
                $childProcess = $null
                try {
                    $logsRoot = Join-Path $fixture ".runtime\logs"
                    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
                    $stdoutPath = Join-Path $logsRoot "detached.stdout.log"
                    $stderrPath = Join-Path $logsRoot "detached.stderr.log"
                    $pidPath = Join-Path $fixture ".runtime\detached.pid"
                    $parentScriptPath = Join-Path $fixture "detached-parent.ps1"
                    $startScriptLiteral = (Get-StartScriptPath).Replace("'", "''")
                    $fixtureLiteral = $fixture.Replace("'", "''")
                    $stdoutLiteral = $stdoutPath.Replace("'", "''")
                    $stderrLiteral = $stderrPath.Replace("'", "''")
                    $pidLiteral = $pidPath.Replace("'", "''")
                    $childCode = "Write-Output 'DETACHED-FIRST'; Start-Sleep -Seconds 2; Write-Output 'DETACHED-SECOND'; Start-Sleep -Seconds 10"
                    $childCodeLiteral = $childCode.Replace("'", "''")
                    $parentScript = @"
`$ErrorActionPreference = 'Stop'
. '$startScriptLiteral' -ProjectRoot '$fixtureLiteral'
Initialize-StartEnvironment
`$launch = Start-ManagedProcess -LaunchSpec ([pscustomobject]@{
    FilePath = (Join-Path `$PSHOME 'powershell.exe')
    ArgumentList = @('-NoProfile', '-Command', '$childCodeLiteral')
    WorkingDirectory = '$fixtureLiteral'
    StdOutLogPath = '$stdoutLiteral'
    StdErrLogPath = '$stderrLiteral'
    IntendedCommandLine = 'detached-boundary-probe'
})
[System.IO.File]::WriteAllText('$pidLiteral', [string]`$launch.Process.Id, [System.Text.Encoding]::ASCII)
`$launch.Process.Dispose()
exit 0
"@
                    Set-Content -LiteralPath $parentScriptPath -Value $parentScript -Encoding ASCII

                    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
                    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + (ConvertTo-StopTestArgument -Argument $parentScriptPath)
                    $startInfo.WorkingDirectory = $fixture
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $parent = New-Object System.Diagnostics.Process
                    $parent.StartInfo = $startInfo
                    [void]$parent.Start()
                    Assert-True -Condition $parent.WaitForExit(10000) -Message "Starter process should exit while the detached child remains alive."
                    Assert-Equal -Expected 0 -Actual $parent.ExitCode -Message "Detached-process parent should exit successfully."

                    Assert-True -Condition (Test-Path -LiteralPath $pidPath -PathType Leaf) -Message "Starter should publish the detached child PID."
                    $childProcessId = [int](Get-Content -LiteralPath $pidPath -Raw)
                    $childProcess = Get-Process -Id $childProcessId -ErrorAction Stop
                    Assert-False -Condition $childProcess.HasExited -Message "Detached child should still run after its starter exits."

                    $deadline = [datetime]::UtcNow.AddSeconds(5)
                    $logContent = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
                    while ([datetime]::UtcNow -lt $deadline -and -not ($logContent -like "*DETACHED-SECOND*")) {
                        Start-Sleep -Milliseconds 100
                        $logContent = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
                    }
                    Assert-Contains -ExpectedSubstring "DETACHED-FIRST" -Actual $logContent -Message "Detached child should write its first log line."
                    Assert-Contains -ExpectedSubstring "DETACHED-SECOND" -Actual $logContent -Message "Detached child logging should continue after the starter exits."
                } finally {
                    if ($null -ne $childProcess) {
                        try {
                            if (-not $childProcess.HasExited) {
                                $childProcess.Kill()
                                [void]$childProcess.WaitForExit(5000)
                            }
                        } finally {
                            $childProcess.Dispose()
                        }
                    }
                    if ($null -ne $parent) {
                        $parent.Dispose()
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: doctor failure prevents state or log mutation and never launches processes"
            Body = {
                $fixture = New-StartFixture
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $launched = $false
                    $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 1; StdOut = "[FAIL] setup"; StdErr = "" } }
                    $launcher = {
                        param($LaunchSpec)
                        $script:launched = $true
                        throw "launcher-should-not-run"
                    }.GetNewClosure()

                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort (Get-TestTcpPort) -FrontendPort (Get-TestTcpPort) -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher | Out-Null
                        throw "Expected doctor failure."
                    } catch {
                        Assert-Contains -ExpectedSubstring "doctor" -Actual $_.Exception.Message.ToLowerInvariant() -Message "Doctor failure should mention doctor."
                    }

                    Assert-False -Condition $launched -Message "Doctor failure must prevent any process launch."
                    Assert-False -Condition (Test-Path -LiteralPath (Join-Path $fixture ".runtime\state")) -Message "Doctor failure must not create the state directory."
                    Assert-False -Condition (Test-Path -LiteralPath (Join-Path $fixture ".runtime\logs")) -Message "Doctor failure must not create the logs directory."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: unrelated occupied random port rejects and the listener survives"
            Body = {
                $fixture = New-StartFixture
                $occupied = $null
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $occupied = Start-TestTcpListener
                    $frontendPort = Get-TestTcpPort
                    $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                    $launcher = { param($LaunchSpec) throw "launcher-should-not-run" }

                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort $occupied.Port -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher | Out-Null
                        throw "Expected occupied-port failure."
                    } catch {
                        $message = $_.Exception.Message.ToLowerInvariant()
                        Assert-Contains -ExpectedSubstring "backend" -Actual $message -Message "Occupied backend failure should mention backend."
                        Assert-Contains -ExpectedSubstring "occupied" -Actual $message -Message "Occupied backend failure should mention the occupied port."
                    }

                    $probe = New-Object System.Net.Sockets.TcpClient
                    try {
                        $connectTask = $probe.ConnectAsync([System.Net.IPAddress]::Loopback, $occupied.Port)
                        [void]$connectTask.Wait(2000)
                        Assert-True -Condition $probe.Connected -Message "Unrelated listener should survive start refusal."
                    } finally {
                        $probe.Dispose()
                    }
                } finally {
                    if ($null -ne $occupied) {
                        $occupied.Listener.Stop()
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: port status resolves the exact listener process id"
            Body = {
                $occupied = $null
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment
                    $occupied = Start-TestTcpListener

                    $status = Get-StartPortStatus -Port $occupied.Port
                    Assert-True -Condition ([bool]$status.Occupied) -Message "Started TCP listener should be reported as occupied."
                    Assert-Equal -Expected $PID -Actual ([int]$status.ProcessId) -Message "Port status should resolve the exact listener process id."
                } finally {
                    if ($null -ne $occupied) {
                        $occupied.Listener.Stop()
                    }
                }
            }
        },
        @{
            Name = "START: identity capture failure stops the launched handle before state write"
            Body = {
                $fixture = New-StartFixture
                $launchState = [pscustomobject]@{ Child = $null; ProcessId = $null }
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                    $launcher = {
                        param($LaunchSpec)
                        $launchState.Child = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role backend -Secret "SENTINEL-START-IDENTITY-FAILURE" -SkipIdentityCapture
                        $launchState.ProcessId = [int]$launchState.Child.Process.Id
                        return [pscustomobject]@{
                            Process = $launchState.Child.Process
                            IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine
                        }
                    }.GetNewClosure()
                    $identityProvider = { param($ProcessHandle, $IntendedCommandLine) throw "identity-capture-failed" }
                    $ready = { param($ReadySpec) return $true }

                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort (Get-TestTcpPort) -FrontendPort (Get-TestTcpPort) -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -ProcessIdentityProvider $identityProvider -BackendReadyWaiter $ready -FrontendReadyWaiter $ready | Out-Null
                        throw "Expected identity capture failure."
                    } catch {
                        Assert-Contains -ExpectedSubstring "identity-capture-failed" -Actual $_.Exception.Message -Message "Identity failure should surface its cause."
                    }

                    Start-Sleep -Milliseconds 300
                    Assert-False -Condition ([bool](Get-Process -Id $launchState.ProcessId -ErrorAction SilentlyContinue)) -Message "Identity failure must stop the process launched before state creation."
                    Assert-False -Condition (Test-Path -LiteralPath (Get-StopFixtureStatePath -ProjectRoot $fixture -Role backend)) -Message "Identity failure must not leave a backend state record."
                } finally {
                    Stop-StopTestChildProcess -Child $launchState.Child
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: injected success writes backend and frontend records atomically and emits safe URLs and log paths"
            Body = {
                $fixture = New-StartFixture
                $launchState = [pscustomobject]@{ Count = 0; BackendChild = $null; FrontendChild = $null; BackendStartHandle = $null; FrontendStartHandle = $null }
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment
                    $startParameters = (Get-Command Invoke-StartMain).Parameters
                    Assert-True -Condition $startParameters.ContainsKey("ProcessIdentityProvider") -Message "Invoke-StartMain should expose a private launched-process identity seam."

                    $backendPort = Get-TestTcpPort
                    $frontendPort = Get-TestTcpPort
                    $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                    $launcher = {
                        param($LaunchSpec)
                        $launchState.Count++
                        if ($launchState.Count -eq 1) {
                            $launchState.BackendChild = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role backend -Secret "SENTINEL-START-SUCCESS-BACKEND" -SkipIdentityCapture
                            $launchState.BackendStartHandle = New-StartTrackedProcessHandle -ProcessHandle $launchState.BackendChild.Process
                            return [pscustomobject]@{
                                Process = $launchState.BackendStartHandle
                                IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine
                                StdOutLogPath = [string]$LaunchSpec.StdOutLogPath
                                StdErrLogPath = [string]$LaunchSpec.StdErrLogPath
                            }
                        }

                        $launchState.FrontendChild = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role frontend -Secret "SENTINEL-START-SUCCESS-FRONTEND" -SkipIdentityCapture
                        $launchState.FrontendStartHandle = New-StartTrackedProcessHandle -ProcessHandle $launchState.FrontendChild.Process
                        return [pscustomobject]@{
                            Process = $launchState.FrontendStartHandle
                            IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine
                            StdOutLogPath = [string]$LaunchSpec.StdOutLogPath
                            StdErrLogPath = [string]$LaunchSpec.StdErrLogPath
                        }
                    }.GetNewClosure()
                    $identityProvider = { param($ProcessHandle, $IntendedCommandLine) New-StartSyntheticIdentity -ProcessHandle $ProcessHandle -CommandLine $IntendedCommandLine }
                    $postStartPortStatusProvider = {
                        param($Port)
                        if ($Port -eq $backendPort) {
                            return [pscustomobject]@{ Occupied = $true; ProcessId = [int]$launchState.BackendChild.Process.Id }
                        }
                        return [pscustomobject]@{ Occupied = $true; ProcessId = [int]$launchState.FrontendChild.Process.Id }
                    }.GetNewClosure()
                    $ready = { param($ReadySpec) return $true }

                    $result = Invoke-StartMain -ProjectRoot $fixture -BackendPort $backendPort -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -ProcessIdentityProvider $identityProvider -PostStartPortStatusProvider $postStartPortStatusProvider -BackendReadyWaiter $ready -FrontendReadyWaiter $ready
                    Assert-Equal -Expected 2 -Actual $launchState.Count -Message "Injected success should launch both roles exactly once."
                    Assert-Equal -Expected "http://127.0.0.1:$frontendPort" -Actual $result.FrontendUrl -Message "Frontend URL mismatch."
                    Assert-Equal -Expected "http://127.0.0.1:$backendPort/docs" -Actual $result.BackendDocsUrl -Message "Backend docs URL mismatch."
                    Assert-True -Condition ($result.Messages.Count -ge 4) -Message "Injected success should return safe summary messages."
                    Assert-False -Condition (($result.Messages -join "`n").Contains("SENTINEL-START-SUCCESS")) -Message "Start success output leaked a secret."
                    Assert-False -Condition (($result.Messages -join "`n").Contains("project-role-backend")) -Message "Start success output leaked the raw backend command line."
                    foreach ($startHandle in @($launchState.BackendStartHandle, $launchState.FrontendStartHandle)) {
                        Assert-True -Condition ([bool]$startHandle.Tracker.Disposed) -Message "Successful start should dispose its temporary process handles."
                    }

                    foreach ($role in @("backend", "frontend")) {
                        $recordPath = Get-StopFixtureStatePath -ProjectRoot $fixture -Role $role
                        Assert-True -Condition (Test-Path -LiteralPath $recordPath -PathType Leaf) -Message "Injected success should write the $role record."
                        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
                        Assert-Equal -Expected 1 -Actual ([int]$record.schemaVersion) -Message "$role schemaVersion mismatch."
                        Assert-Equal -Expected $fixture -Actual ([string]$record.projectRoot) -Message "$role projectRoot mismatch."
                        Assert-Equal -Expected $role -Actual ([string]$record.role) -Message "$role role mismatch."
                        Assert-True -Condition ([int]$record.pid -gt 0) -Message "$role pid must be positive."
                        Assert-True -Condition ([string]$record.startTimeUtc).EndsWith("Z", [System.StringComparison]::Ordinal) -Message "$role startTimeUtc must be UTC roundtrip."
                        Assert-Contains -ExpectedSubstring $fixture -Actual ([string]$record.commandLine) -Message "$role commandLine should contain the project root."
                        Assert-Contains -ExpectedSubstring "project-role-$role" -Actual ([string]$record.commandLine) -Message "$role commandLine should contain the role marker."
                    }
                } finally {
                    Stop-StopTestChildProcess -Child $launchState.BackendChild
                    Stop-StopTestChildProcess -Child $launchState.FrontendChild
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: readiness failure stops only the started handles, removes their records, and preserves logs"
            Body = {
                $cases = @(
                    [pscustomobject]@{
                        Name = "backend"
                        BackendReady = $false
                        FrontendReady = $true
                        OwnershipMatches = $true
                    },
                    [pscustomobject]@{
                        Name = "frontend"
                        BackendReady = $true
                        FrontendReady = $false
                        OwnershipMatches = $true
                    },
                    [pscustomobject]@{
                        Name = "ownership"
                        BackendReady = $true
                        FrontendReady = $true
                        OwnershipMatches = $false
                    }
                )

                foreach ($case in $cases) {
                    $fixture = New-StartFixture
                    $launchState = [pscustomobject]@{ Count = 0; BackendChild = $null; FrontendChild = $null; BackendPid = $null; FrontendPid = $null }
                    try {
                        . (Get-StartScriptPath)
                        Initialize-StartEnvironment

                        $backendPort = Get-TestTcpPort
                        $frontendPort = Get-TestTcpPort
                        $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                        $launcher = {
                            param($LaunchSpec)
                            $launchState.Count++
                            if ($launchState.Count -eq 1) {
                                $launchState.BackendChild = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role backend -Secret "SENTINEL-START-READY-BACKEND" -SkipIdentityCapture
                                $launchState.BackendPid = [int]$launchState.BackendChild.Process.Id
                                Set-Content -LiteralPath $LaunchSpec.StdOutLogPath -Value "backend-log" -Encoding ASCII
                                Set-Content -LiteralPath $LaunchSpec.StdErrLogPath -Value "" -Encoding ASCII
                                return [pscustomobject]@{
                                    Process = $launchState.BackendChild.Process
                                    IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine
                                    StdOutLogPath = [string]$LaunchSpec.StdOutLogPath
                                    StdErrLogPath = [string]$LaunchSpec.StdErrLogPath
                                }
                            }

                            $launchState.FrontendChild = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role frontend -Secret "SENTINEL-START-READY-FRONTEND" -SkipIdentityCapture
                            $launchState.FrontendPid = [int]$launchState.FrontendChild.Process.Id
                            Set-Content -LiteralPath $LaunchSpec.StdOutLogPath -Value "frontend-log" -Encoding ASCII
                            Set-Content -LiteralPath $LaunchSpec.StdErrLogPath -Value "" -Encoding ASCII
                            return [pscustomobject]@{
                                Process = $launchState.FrontendChild.Process
                                IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine
                                StdOutLogPath = [string]$LaunchSpec.StdOutLogPath
                                StdErrLogPath = [string]$LaunchSpec.StdErrLogPath
                            }
                        }.GetNewClosure()
                        $identityProvider = { param($ProcessHandle, $IntendedCommandLine) New-StartSyntheticIdentity -ProcessHandle $ProcessHandle -CommandLine $IntendedCommandLine }
                        $postStartPortStatusProvider = {
                            param($Port)
                            if (-not $case.OwnershipMatches) {
                                return [pscustomobject]@{ Occupied = $true; ProcessId = 1 }
                            }
                            if ($Port -eq $backendPort) {
                                return [pscustomobject]@{ Occupied = $true; ProcessId = [int]$launchState.BackendPid }
                            }
                            return [pscustomobject]@{ Occupied = $true; ProcessId = [int]$launchState.FrontendPid }
                        }.GetNewClosure()
                        $backendReadyWaiter = { param($ReadySpec) return $case.BackendReady }.GetNewClosure()
                        $frontendReadyWaiter = { param($ReadySpec) return $case.FrontendReady }.GetNewClosure()

                        $readinessError = $null
                        try {
                            Invoke-StartMain -ProjectRoot $fixture -BackendPort $backendPort -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -ProcessIdentityProvider $identityProvider -PostStartPortStatusProvider $postStartPortStatusProvider -BackendReadyWaiter $backendReadyWaiter -FrontendReadyWaiter $frontendReadyWaiter | Out-Null
                        } catch {
                            $readinessError = $_
                        }
                        Assert-True -Condition ($null -ne $readinessError) -Message "Expected readiness failure for $($case.Name)."
                        Assert-Contains -ExpectedSubstring $case.Name -Actual $readinessError.Exception.Message.ToLowerInvariant() -Message "Readiness failure should mention the failing role."

                        foreach ($role in @("backend", "frontend")) {
                            $recordPath = Get-StopFixtureStatePath -ProjectRoot $fixture -Role $role
                            Assert-False -Condition (Test-Path -LiteralPath $recordPath) -Message "Readiness failure should remove the $role record."
                        }

                        foreach ($processId in @($launchState.BackendPid, $launchState.FrontendPid)) {
                            if ($null -ne $processId) {
                                Start-Sleep -Milliseconds 300
                                Assert-False -Condition ([bool](Get-Process -Id $processId -ErrorAction SilentlyContinue)) -Message "Readiness failure should stop every started child handle."
                            }
                        }

                        foreach ($leaf in @("backend.stdout.log", "backend.stderr.log", "frontend.stdout.log", "frontend.stderr.log")) {
                            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $fixture ".runtime\logs\$leaf") -PathType Leaf) -Message "Readiness failure should preserve log file '$leaf'."
                        }
                    } finally {
                        Stop-StopTestChildProcess -Child $launchState.BackendChild
                        Stop-StopTestChildProcess -Child $launchState.FrontendChild
                        Remove-TempFixture -Path $fixture
                    }
                }
            }
        },
        @{
            Name = "START: rollback preserves records and surfaces process stop failures"
            Body = {
                $fixture = New-StartFixture
                $launchState = [pscustomobject]@{ Count = 0; BackendChild = $null; FrontendChild = $null }
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                    $launcher = {
                        param($LaunchSpec)
                        $launchState.Count++
                        if ($launchState.Count -eq 1) {
                            $launchState.BackendChild = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role backend -Secret "SENTINEL-START-STOP-FAILURE-BACKEND" -SkipIdentityCapture
                            return [pscustomobject]@{ Process = $launchState.BackendChild.Process; IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine }
                        }
                        $launchState.FrontendChild = Start-StopTestChildProcess -ProjectRoot $LaunchSpec.ProjectRoot -Role frontend -Secret "SENTINEL-START-STOP-FAILURE-FRONTEND" -SkipIdentityCapture
                        return [pscustomobject]@{ Process = $launchState.FrontendChild.Process; IntendedCommandLine = [string]$LaunchSpec.IntendedCommandLine }
                    }.GetNewClosure()
                    $identityProvider = { param($ProcessHandle, $IntendedCommandLine) New-StartSyntheticIdentity -ProcessHandle $ProcessHandle -CommandLine $IntendedCommandLine }
                    $processStopper = { param($Started, $StopTimeoutSeconds) throw "injected-stop-failure" }
                    $backendReadyWaiter = { param($ReadySpec) return $false }
                    $frontendReadyWaiter = { param($ReadySpec) return $true }

                    $startError = $null
                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort (Get-TestTcpPort) -FrontendPort (Get-TestTcpPort) -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -ProcessIdentityProvider $identityProvider -ProcessStopper $processStopper -BackendReadyWaiter $backendReadyWaiter -FrontendReadyWaiter $frontendReadyWaiter | Out-Null
                    } catch {
                        $startError = $_
                    }

                    Assert-True -Condition ($null -ne $startError) -Message "Injected process-stop failure should fail start."
                    Assert-Contains -ExpectedSubstring "cleanup" -Actual $startError.Exception.Message.ToLowerInvariant() -Message "Start should report rollback cleanup failure."
                    Assert-Contains -ExpectedSubstring "injected-stop-failure" -Actual $startError.Exception.Message -Message "Start should preserve the process-stop failure cause."
                    foreach ($role in @("backend", "frontend")) {
                        Assert-True -Condition (Test-Path -LiteralPath (Get-StopFixtureStatePath -ProjectRoot $fixture -Role $role) -PathType Leaf) -Message "Failed process cleanup must preserve the $role state record."
                    }
                    Assert-True -Condition ([bool](Get-Process -Id $launchState.BackendChild.Process.Id -ErrorAction SilentlyContinue)) -Message "Injected backend stop failure should leave the child alive and recorded."
                    Assert-True -Condition ([bool](Get-Process -Id $launchState.FrontendChild.Process.Id -ErrorAction SilentlyContinue)) -Message "Injected frontend stop failure should leave the child alive and recorded."
                } finally {
                    Stop-StopTestChildProcess -Child $launchState.BackendChild
                    Stop-StopTestChildProcess -Child $launchState.FrontendChild
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: matching recorded healthy processes return idempotent without launching"
            Body = {
                $fixture = New-StartFixture
                $backendChild = $null
                $frontendChild = $null
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $backendChild = Start-StopTestChildProcess -ProjectRoot $fixture -Role backend -Secret "SENTINEL-START-IDEMPOTENT-BACKEND" -SkipIdentityCapture
                    $frontendChild = Start-StopTestChildProcess -ProjectRoot $fixture -Role frontend -Secret "SENTINEL-START-IDEMPOTENT-FRONTEND" -SkipIdentityCapture
                    $backendIdentity = New-StartSyntheticIdentity -ProcessHandle $backendChild.Process -CommandLine $backendChild.IntendedCommandLine
                    $frontendIdentity = New-StartSyntheticIdentity -ProcessHandle $frontendChild.Process -CommandLine $frontendChild.IntendedCommandLine
                    $backendRecord = New-StopRecordFromSyntheticIdentity -Child $backendChild -ActualIdentity $backendIdentity
                    $frontendRecord = New-StopRecordFromSyntheticIdentity -Child $frontendChild -ActualIdentity $frontendIdentity
                    [void](Write-StopProcessRecord -ProjectRoot $fixture -Role backend -Record $backendRecord)
                    [void](Write-StopProcessRecord -ProjectRoot $fixture -Role frontend -Record $frontendRecord)

                    $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                    $launcher = {
                        param($LaunchSpec)
                        throw "launcher-should-not-run"
                    }
                    $backendPort = Get-TestTcpPort
                    $frontendPort = Get-TestTcpPort
                    $portProvider = {
                        param($Port)
                        switch ($Port) {
                            $backendPort { return [pscustomobject]@{ Occupied = $true; ProcessId = $backendChild.Process.Id } }
                            $frontendPort { return [pscustomobject]@{ Occupied = $true; ProcessId = $frontendChild.Process.Id } }
                            default { return [pscustomobject]@{ Occupied = $false; ProcessId = $null } }
                        }
                    }.GetNewClosure()
                    $identities = @{
                        ([int]$backendChild.Process.Id) = $backendIdentity
                        ([int]$frontendChild.Process.Id) = $frontendIdentity
                    }
                    $existingIdentityProvider = { param($ProcessHandle) $identities[[int]$ProcessHandle.Id] }.GetNewClosure()
                    $ready = { param($ReadySpec) return $true }

                    $freePortProvider = { param($Port) [pscustomobject]@{ Occupied = $false; ProcessId = $null } }
                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort $backendPort -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -PortStatusProvider $freePortProvider -ExistingIdentityProvider $existingIdentityProvider -BackendReadyWaiter $ready -FrontendReadyWaiter $ready | Out-Null
                        throw "Expected live recorded process refusal on free ports."
                    } catch {
                        Assert-Contains -ExpectedSubstring "recorded" -Actual $_.Exception.Message.ToLowerInvariant() -Message "Live recorded processes must not be overwritten when ports appear free."
                    }

                    $unknownOwnerPortProvider = {
                        param($Port)
                        return [pscustomobject]@{ Occupied = $true; ProcessId = $null }
                    }
                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort $backendPort -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -PortStatusProvider $unknownOwnerPortProvider -ExistingIdentityProvider $existingIdentityProvider -BackendReadyWaiter $ready -FrontendReadyWaiter $ready | Out-Null
                        throw "Expected unknown port owner refusal."
                    } catch {
                        Assert-Contains -ExpectedSubstring "occupied" -Actual $_.Exception.Message.ToLowerInvariant() -Message "Unknown listener ownership must fail closed."
                    }

                    $mismatchedBackendIdentity = [pscustomobject]@{
                        Pid = $backendIdentity.Pid
                        ExecutablePath = $backendIdentity.ExecutablePath
                        StartTimeUtc = $backendIdentity.StartTimeUtc
                        CommandLine = $backendIdentity.CommandLine + " mismatched"
                    }
                    $mismatchedIdentities = @{
                        ([int]$backendChild.Process.Id) = $mismatchedBackendIdentity
                        ([int]$frontendChild.Process.Id) = $frontendIdentity
                    }
                    $mismatchedIdentityProvider = { param($ProcessHandle) $mismatchedIdentities[[int]$ProcessHandle.Id] }.GetNewClosure()
                    try {
                        Invoke-StartMain -ProjectRoot $fixture -BackendPort $backendPort -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -PortStatusProvider $portProvider -ExistingIdentityProvider $mismatchedIdentityProvider -BackendReadyWaiter $ready -FrontendReadyWaiter $ready | Out-Null
                        throw "Expected mismatched command-line refusal."
                    } catch {
                        Assert-Contains -ExpectedSubstring "occupied" -Actual $_.Exception.Message.ToLowerInvariant() -Message "Mismatched actual command line must fail closed."
                    }

                    $result = Invoke-StartMain -ProjectRoot $fixture -BackendPort $backendPort -FrontendPort $frontendPort -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher -PortStatusProvider $portProvider -ExistingIdentityProvider $existingIdentityProvider -BackendReadyWaiter $ready -FrontendReadyWaiter $ready
                    Assert-Equal -Expected "http://127.0.0.1:$frontendPort" -Actual $result.FrontendUrl -Message "Idempotent frontend URL mismatch."
                    Assert-Equal -Expected "http://127.0.0.1:$backendPort/docs" -Actual $result.BackendDocsUrl -Message "Idempotent backend docs URL mismatch."
                    Assert-Contains -ExpectedSubstring "already running" -Actual (($result.Messages -join "`n").ToLowerInvariant()) -Message "Idempotent start should report already-running services."
                    Assert-True -Condition ([bool](Get-Process -Id $backendChild.Process.Id -ErrorAction SilentlyContinue)) -Message "Idempotent backend child should remain running."
                    Assert-True -Condition ([bool](Get-Process -Id $frontendChild.Process.Id -ErrorAction SilentlyContinue)) -Message "Idempotent frontend child should remain running."
                } finally {
                    Stop-StopTestChildProcess -Child $backendChild
                    Stop-StopTestChildProcess -Child $frontendChild
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: malformed or reparse state refuses before launch"
            Body = {
                $cases = @(
                    [pscustomobject]@{
                        Name = "malformed"
                        Setup = {
                            param($FixtureRoot)
                            New-Item -ItemType Directory -Path (Join-Path $FixtureRoot ".runtime\state") -Force | Out-Null
                            Set-Content -LiteralPath (Join-Path $FixtureRoot ".runtime\state\backend.json") -Value "{not-json" -Encoding ASCII
                        }
                        Expected = "invalid"
                    },
                    [pscustomobject]@{
                        Name = "reparse"
                        Setup = {
                            param($FixtureRoot)
                            $external = New-TempFixture
                            New-Item -ItemType Directory -Path (Join-Path $FixtureRoot ".runtime") -Force | Out-Null
                            New-Item -ItemType Directory -Path $external -Force | Out-Null
                            New-Item -ItemType Junction -Path (Join-Path $FixtureRoot ".runtime\state") -Target $external | Out-Null
                            return $external
                        }
                        Expected = "reparse point"
                    },
                    [pscustomobject]@{
                        Name = "log-reparse"
                        Setup = {
                            param($FixtureRoot)
                            $external = New-TempFixture
                            $logsRoot = Join-Path $FixtureRoot ".runtime\logs"
                            New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
                            New-Item -ItemType Directory -Path $external -Force | Out-Null
                            New-Item -ItemType Junction -Path (Join-Path $logsRoot "backend.stdout.log") -Target $external | Out-Null
                            return $external
                        }
                        Expected = "reparse point"
                    }
                )

                foreach ($case in $cases) {
                    $fixture = New-StartFixture
                    $external = $null
                    try {
                        . (Get-StartScriptPath)
                        Initialize-StartEnvironment
                        $external = & $case.Setup $fixture

                        $doctorRunner = { param($RootPath, $DoctorTimeoutSeconds) [pscustomobject]@{ ExitCode = 0; StdOut = "[PASS] doctor"; StdErr = "" } }
                        $launcher = { param($LaunchSpec) throw "launcher-should-not-run" }

                        try {
                            Invoke-StartMain -ProjectRoot $fixture -BackendPort (Get-TestTcpPort) -FrontendPort (Get-TestTcpPort) -TimeoutSeconds 5 -DoctorRunner $doctorRunner -ProcessLauncher $launcher | Out-Null
                            throw "Expected $($case.Name) refusal."
                        } catch {
                            Assert-Contains -ExpectedSubstring $case.Expected -Actual $_.Exception.Message.ToLowerInvariant() -Message "Start refusal mismatch for the $($case.Name) state case."
                        }
                    } finally {
                        if ($external) {
                            Remove-TempFixture -Path $external
                        }
                        Remove-TempFixture -Path $fixture
                    }
                }
            }
        },
        @{
            Name = "START: state writer rename failure preserves no partial final record"
            Body = {
                $fixture = New-StartFixture
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment

                    $record = [ordered]@{
                        schemaVersion = 1
                        pid = 424242
                        executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                        startTimeUtc = [datetime]::UtcNow.ToString("o")
                        commandLine = "powershell.exe -NoProfile # project-role-backend $fixture"
                        projectRoot = $fixture
                        role = "backend"
                    }
                    $stateDirectory = Join-Path $fixture ".runtime\state"
                    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
                    $statePath = Join-Path $stateDirectory "backend.json"

                    try {
                        Write-StartStateRecord -RootPath $fixture -Role backend -Record $record -MoveAction { param($LiteralPath, $Destination) throw "rename-failed" }
                        throw "Expected rename failure."
                    } catch {
                        Assert-Contains -ExpectedSubstring "rename-failed" -Actual $_.Exception.Message -Message "Rename failure should surface the move failure."
                    }

                    Assert-False -Condition (Test-Path -LiteralPath $statePath -PathType Leaf) -Message "Rename failure should leave no final record."
                    Assert-Equal -Expected 0 -Actual @((Get-ChildItem -LiteralPath $stateDirectory -Force -ErrorAction SilentlyContinue)).Count -Message "Rename failure should leave no temp state leaf behind."

                    $existingRecord = [ordered]@{
                        schemaVersion = 1
                        pid = 515151
                        executablePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                        startTimeUtc = [datetime]::UtcNow.ToString("o")
                        commandLine = "existing project-role-backend $fixture"
                        projectRoot = $fixture
                        role = "backend"
                    }
                    $existingJson = $existingRecord | ConvertTo-Json -Depth 4 -Compress
                    [System.IO.File]::WriteAllText($statePath, $existingJson, [System.Text.Encoding]::UTF8)
                    $collisionError = $null
                    try {
                        Write-StartStateRecord -RootPath $fixture -Role backend -Record $record | Out-Null
                    } catch {
                        $collisionError = $_
                    }
                    Assert-True -Condition ($null -ne $collisionError) -Message "Atomic state creation must refuse an existing final record."
                    Assert-Equal -Expected $existingJson -Actual (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8) -Message "State collision must preserve the existing record."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "START: generated records integrate with stop state reading and injected stop handle flow"
            Body = {
                $fixture = New-StartFixture
                $child = $null
                try {
                    . (Get-StartScriptPath)
                    Initialize-StartEnvironment
                    $child = Start-StopTestChildProcess -ProjectRoot $fixture -Role backend -Secret "SENTINEL-START-STOP-INTEGRATION" -SkipIdentityCapture
                    $actualCommandLine = ([string]$child.IntendedCommandLine) + " test-path"
                    $identity = New-StartSyntheticIdentity -ProcessHandle $child.Process -CommandLine $actualCommandLine
                    $identityProvider = { param($ProcessHandle, $IntendedCommandLine) $identity }.GetNewClosure()
                    $record = New-StartStateRecord -RootPath $fixture -Role backend -ProcessHandle $child.Process -IntendedCommandLine "constructed-command-must-not-be-stored" -IdentityProvider $identityProvider
                    Assert-Equal -Expected $actualCommandLine -Actual ([string]$record.commandLine) -Message "Start record should store the captured actual command line."

                    $statePath = Write-StartStateRecord -RootPath $fixture -Role backend -Record $record
                    $readRecord = Read-StopStateRecord -StatePath $statePath -Role backend -ProjectRoot $fixture
                    Assert-Equal -Expected ([int]$identity.Pid) -Actual ([int]$readRecord.pid) -Message "Stop reader should accept the start record pid."
                    Assert-Equal -Expected $actualCommandLine -Actual ([string]$readRecord.commandLine) -Message "Stop reader should preserve the actual command line."

                    $actualIdentity = [pscustomobject]@{
                        Pid = [int]$identity.Pid
                        ExecutablePath = [string]$identity.ExecutablePath
                        StartTimeUtc = ([datetime]$identity.StartTimeUtc).ToUniversalTime()
                        CommandLine = $actualCommandLine
                    }
                    $identityProvider = { param($ProcessHandle) $actualIdentity }.GetNewClosure()
                    $identityComparer = {
                        param($RecordedIdentity, $ProcessHandle, $ActualIdentity)
                        if ([int]$RecordedIdentity.Pid -ne [int]$ActualIdentity.Pid) { return $false }
                        if (-not ([System.IO.Path]::GetFullPath([string]$RecordedIdentity.ExecutablePath)).Equals([System.IO.Path]::GetFullPath([string]$ActualIdentity.ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                        $recordedStart = [datetime]::Parse([string]$RecordedIdentity.StartTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
                        if ($recordedStart -ne ([datetime]$ActualIdentity.StartTimeUtc).ToUniversalTime()) { return $false }
                        return ([string]$RecordedIdentity.CommandLine).Equals([string]$ActualIdentity.CommandLine, [System.StringComparison]::Ordinal)
                    }.GetNewClosure()

                    $stopResult = Stop-ManagedRole -RootPath $fixture -Role backend -TimeoutSeconds 5 -IdentityProvider $identityProvider -IdentityComparer $identityComparer
                    Assert-True -Condition ([bool]$stopResult.Success) -Message "Stop handle flow should accept a start-written record when actual command line is supplied."
                    Assert-False -Condition (Test-Path -LiteralPath $statePath) -Message "Successful stop should remove the start-written record."
                } finally {
                    Stop-StopTestChildProcess -Child $child
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "SkipRuntimeDownload fails when compatible runtimes are unavailable locally and on PATH"
            Body = {
                $fixture = New-BootstrapFixture
                try {
                    $result = Invoke-BootstrapScriptProcess -ProjectRoot $fixture -ArgumentList @(
                        "-Device",
                        "cpu",
                        "-SkipRuntimeDownload",
                        "-SkipModels",
                        "-DisablePathRuntimeProbe",
                        "-OsArchitectureOverride",
                        "x64",
                        "-FreeSpaceGbOverride",
                        "8"
                    )

                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "SkipRuntimeDownload should fail when no runtimes exist."
                    Assert-Contains -ExpectedSubstring "SkipRuntimeDownload" -Actual ($result.StdOut + $result.StdErr) -Message "Missing runtime failure should mention SkipRuntimeDownload."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor script AST parses cleanly, exposes the expected parameters, and stays idle when dot-sourced"
            Body = {
                $doctorScriptPath = Get-DoctorScriptPath
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($doctorScriptPath, [ref]$tokens, [ref]$parseErrors)

                Assert-Equal -Expected 0 -Actual $parseErrors.Count -Message "Doctor script parse errors were found."

                $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                foreach ($parameterName in @("Device", "Json", "ProjectRoot")) {
                    Assert-True -Condition ($parameterNames -contains $parameterName) -Message "Missing required doctor parameter '$parameterName'."
                }

                $escapedDoctorPath = $doctorScriptPath.Replace("'", "''")
                $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$escapedDoctorPath'
'dot-sourced'
"@
                $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory (Split-Path -Parent $doctorScriptPath)
                Assert-Equal -Expected "dot-sourced" -Actual $result.StdOut.Trim() -Message "Doctor script should not auto-run when dot-sourced."
                Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Doctor script emitted unexpected stderr when dot-sourced."
            }
        },
        @{
            Name = "Doctor disk facts use DriveInfo when PSDrive reports zero"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-Item {
    param([string]`$LiteralPath, [switch]`$Force, [string]`$ErrorAction)
    return [pscustomobject]@{ PSDrive = [pscustomobject]@{ Free = [int64]0 } }
}
`$facts = Get-DoctorSystemFacts -ProjectRoot '$escapedFixture'
`$driveInfo = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot('$escapedFixture'))
[ordered]@{ Actual = [int64]`$facts.FreeSpaceBytes; Expected = [int64]`$driveInfo.AvailableFreeSpace } | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $diskFacts = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected ([int64]$diskFacts.Expected) -Actual ([int64]$diskFacts.Actual) -Message "Doctor should use DriveInfo rather than an unreliable zero PSDrive.Free value."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor prefers the dependency-bearing backend venv over the base runtime"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $basePythonPath = Join-Path $fixture ".runtime\python\python.exe"
                    New-Item -ItemType Directory -Path (Split-Path -Parent $basePythonPath) -Force | Out-Null
                    [System.IO.File]::WriteAllText($basePythonPath, "fixture-base-python", [System.Text.Encoding]::ASCII)
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorExactPythonVersion {
    param([string]`$PythonPath, [string]`$ProjectRoot, [int]`$TimeoutSeconds)
    return '3.10.11'
}
`$paths = Resolve-DoctorPaths -RootPath '$escapedFixture'
`$info = Get-DoctorPythonInfo -Paths `$paths -Manifest ([pscustomobject]@{ runtime = [pscustomobject]@{ python = [pscustomobject]@{ version = '3.10.11' } } })
[ordered]@{ Source = `$info.Source; Path = `$info.Path } | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $info = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "backend-venv" -Actual ([string]$info.Source) -Message "Doctor should run dependency probes with backend/.venv Python."
                    Assert-Equal -Expected (Join-Path $fixture "backend\.venv\Scripts\python.exe") -Actual ([string]$info.Path) -Message "Doctor selected the wrong Python executable."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor fake fixture passes and human and JSON output stay secret-free"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorSystemFacts {
    param([string]`$ProjectRoot)
    return [pscustomobject]@{
        IsWindows = `$true
        Architecture = 'x64'
        FreeSpaceBytes = 20GB
    }
}
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    return [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    return [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    return [pscustomobject]@{
        ExitCode = 0
        Message = 'pip check passed'
    }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    return [pscustomobject]@{
        Version = '2.7.1+cpu'
        CudaBuild = `$null
        CudaAvailable = `$false
    }
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
[ordered]@{
    ExitCode = `$result.ExitCode
    ResultCount = @(`$result.Results).Count
    Statuses = @(`$result.Results | ForEach-Object { `$_.status })
    Human = (Format-DoctorHumanOutput -Results `$result.Results)
    Json = (Format-DoctorJsonOutput -Results `$result.Results)
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 0 -Actual $state.ExitCode -Message "Doctor fixture should pass."
                    Assert-True -Condition ($state.ResultCount -gt 0) -Message "Doctor should return a non-empty result set."
                    Assert-False -Condition (@($state.Statuses | Where-Object { $_ -eq 'FAIL' }).Count -gt 0) -Message "Doctor fixture should not report FAIL."
                    Assert-Contains -ExpectedSubstring "[PASS]" -Actual $state.Human -Message "Doctor human output should contain PASS markers."
                    Assert-Contains -ExpectedSubstring '"status":"PASS"' -Actual $state.Json -Message "Doctor JSON output should contain PASS records."
                    Assert-False -Condition ($state.Human.Contains("super-secret-fixture-value")) -Message "Doctor human output leaked the fixture secret."
                    Assert-False -Condition ($state.Json.Contains("super-secret-fixture-value")) -Message "Doctor JSON output leaked the fixture secret."

                    $envPath = Join-Path $fixture "backend\.env"
                    $envContent = (Get-Content -LiteralPath $envPath -Raw -Encoding UTF8).Replace("super-secret-fixture-value", "generated-by-bootstrap")
                    Set-Content -LiteralPath $envPath -Value $envContent -Encoding UTF8
                    $markerResult = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $markerState = $markerResult.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 1 -Actual ([int]$markerState.ExitCode) -Message "Doctor must reject the bootstrap JWT template marker."
                    Assert-Contains -ExpectedSubstring '"name":"backend-env","status":"FAIL"' -Actual ([string]$markerState.Json) -Message "Doctor should report backend-env failure for the JWT marker."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor fails with a nonzero exit code when a required model hash is wrong"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    Set-Content -LiteralPath (Join-Path $fixture "models\tt100k-yolo11s-reference42.pt") -Value "corrupted-model" -Encoding ASCII
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorSystemFacts {
    param([string]`$ProjectRoot)
    return [pscustomobject]@{
        IsWindows = `$true
        Architecture = 'x64'
        FreeSpaceBytes = 20GB
    }
}
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    return [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    return [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    return [pscustomobject]@{
        ExitCode = 0
        Message = 'pip check passed'
    }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    return [pscustomobject]@{
        Version = '2.7.1+cpu'
        CudaBuild = `$null
        CudaAvailable = `$false
    }
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
[ordered]@{
    ExitCode = `$result.ExitCode
    Human = (Format-DoctorHumanOutput -Results `$result.Results)
    Json = (Format-DoctorJsonOutput -Results `$result.Results)
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 1 -Actual $state.ExitCode -Message "Doctor should fail when a required model hash is wrong."
                    Assert-Contains -ExpectedSubstring "[FAIL]" -Actual $state.Human -Message "Doctor human output should mark a bad model hash as FAIL."
                    Assert-Contains -ExpectedSubstring "hash" -Actual $state.Human.ToLowerInvariant() -Message "Doctor human output should mention the hash problem."
                    Assert-Contains -ExpectedSubstring '"status":"FAIL"' -Actual $state.Json -Message "Doctor JSON output should include a FAIL record."
                    Assert-False -Condition ($state.Human.Contains("super-secret-fixture-value")) -Message "Doctor failure output leaked the fixture secret."
                    Assert-False -Condition ($state.Json.Contains("super-secret-fixture-value")) -Message "Doctor failure JSON leaked the fixture secret."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor reports an occupied random port as WARN without using the fixed app ports"
            Body = {
                $listenerState = Start-TestTcpListener
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
`$checks = Get-DoctorPortCheckResults -Ports @($($listenerState.Port))
[ordered]@{
    Count = @(`$checks).Count
    Status = `$checks[0].status
    Message = `$checks[0].message
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory (Split-Path -Parent (Get-DoctorScriptPath))
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 1 -Actual $state.Count -Message "Doctor should return one port check result for the random port."
                    Assert-Equal -Expected "WARN" -Actual $state.Status -Message "Occupied doctor port check should WARN."
                    Assert-Contains -ExpectedSubstring ([string]$listenerState.Port) -Actual $state.Message -Message "Port warning should mention the occupied random port."
                } finally {
                    $listenerState.Listener.Stop()
                }
            }
        },
        @{
            Name = "Doctor cpu mode accepts a CUDA torch build as usable for CPU inference without failing"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorSystemFacts {
    param([string]`$ProjectRoot)
    [pscustomobject]@{
        IsWindows = `$true
        Architecture = 'x64'
        FreeSpaceBytes = 20GB
    }
}
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    [pscustomobject]@{
        ExitCode = 0
        Message = 'pip check passed'
    }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    [pscustomobject]@{
        Version = '2.7.1+cu128'
        CudaBuild = '12.8'
        CudaAvailable = `$true
    }
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device cpu
`$torchBuild = @(`$result.Results | Where-Object { `$_.name -eq 'torch-build' })[0]
`$cudaState = @(`$result.Results | Where-Object { `$_.name -eq 'cuda-state' })[0]
[ordered]@{
    ExitCode = `$result.ExitCode
    TorchStatus = `$torchBuild.status
    TorchMessage = `$torchBuild.message
    CudaStatus = `$cudaState.status
    CudaMessage = `$cudaState.message
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 0 -Actual $state.ExitCode -Message "CPU mode should not fail when a CUDA torch wheel is installed."
                    Assert-True -Condition (@("PASS", "WARN") -contains [string]$state.TorchStatus) -Message "CPU CUDA wheel status should be PASS or WARN."
                    Assert-True -Condition (@("PASS", "WARN") -contains [string]$state.CudaStatus) -Message "CPU CUDA availability status should be PASS or WARN."
                    Assert-Contains -ExpectedSubstring "usable" -Actual $state.TorchMessage.ToLowerInvariant() -Message "CPU CUDA wheel message should explain usability."
                    Assert-Contains -ExpectedSubstring "larger" -Actual $state.TorchMessage.ToLowerInvariant() -Message "CPU CUDA wheel message should mention the larger wheel size."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor auto mode emits a compute-device result resolved to gpu when CUDA is available"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorSystemFacts {
    param([string]`$ProjectRoot)
    [pscustomobject]@{
        IsWindows = `$true
        Architecture = 'x64'
        FreeSpaceBytes = 20GB
    }
}
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    [pscustomobject]@{
        ExitCode = 0
        Message = 'pip check passed'
    }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    [pscustomobject]@{
        Version = '2.7.1+cu128'
        CudaBuild = '12.8'
        CudaAvailable = `$true
    }
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
`$compute = @(`$result.Results | Where-Object { `$_.name -eq 'compute-device' })[0]
[ordered]@{
    ExitCode = `$result.ExitCode
    Name = `$compute.name
    Status = `$compute.status
    Message = `$compute.message
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 0 -Actual $state.ExitCode -Message "Auto mode with CUDA available should pass."
                    Assert-Equal -Expected "compute-device" -Actual $state.Name -Message "Compute-device result name mismatch."
                    Assert-Equal -Expected "PASS" -Actual $state.Status -Message "Compute-device result should PASS."
                    Assert-Contains -ExpectedSubstring "gpu" -Actual $state.Message.ToLowerInvariant() -Message "Compute-device message should resolve to GPU."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor auto mode emits a compute-device result resolved to cpu when CUDA is unavailable"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorSystemFacts {
    param([string]`$ProjectRoot)
    [pscustomobject]@{
        IsWindows = `$true
        Architecture = 'x64'
        FreeSpaceBytes = 20GB
    }
}
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    [pscustomobject]@{
        ExitCode = 0
        Message = 'pip check passed'
    }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    [pscustomobject]@{
        Version = '2.7.1+cpu'
        CudaBuild = `$null
        CudaAvailable = `$false
    }
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
`$compute = @(`$result.Results | Where-Object { `$_.name -eq 'compute-device' })[0]
[ordered]@{
    ExitCode = `$result.ExitCode
    Name = `$compute.name
    Status = `$compute.status
    Message = `$compute.message
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 0 -Actual $state.ExitCode -Message "Auto mode with CUDA unavailable should pass."
                    Assert-Equal -Expected "compute-device" -Actual $state.Name -Message "Compute-device result name mismatch."
                    Assert-Equal -Expected "PASS" -Actual $state.Status -Message "Compute-device result should PASS."
                    Assert-Contains -ExpectedSubstring "cpu" -Actual $state.Message.ToLowerInvariant() -Message "Compute-device message should resolve to CPU."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor rejects a project-local Node runtime when npm cannot execute"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $nodeRoot = Join-Path $fixture ".runtime\node"
                    New-Item -ItemType Directory -Path $nodeRoot -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $nodeRoot "node.exe") -Value "fixture-node" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $nodeRoot "npm.cmd") -Value "fixture-npm" -Encoding ASCII

                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorExactNodeVersion {
    param([string]`$NodePath, [string]`$ProjectRoot, [int]`$TimeoutSeconds)
    '24.18.0'
}
function Get-DoctorExactNpmVersion {
    param([string]`$NpmPath, [string]`$ProjectRoot, [int]`$TimeoutSeconds)
    throw 'npm-probe-failed'
}
`$paths = Resolve-DoctorPaths -RootPath '$escapedFixture'
`$manifest = Read-BootstrapManifest -Path `$paths.ManifestPath
try {
    `$null = Get-DoctorNodeInfo -Paths `$paths -Manifest `$manifest
    throw 'Expected npm probe failure.'
} catch {
    `$_.Exception.Message
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    Assert-Contains -ExpectedSubstring "npm-probe-failed" -Actual $result.StdOut.Trim() -Message "Doctor should execute npm and surface a sanitized probe failure."
                    Assert-False -Condition ($result.StdOut.Contains("Expected npm probe failure.")) -Message "Doctor must not accept an npm command that cannot execute."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor rejects a project-local Python runtime routed through a junction before execution"
            Body = {
                $fixture = New-DoctorFixture
                $external = New-TempFixture
                try {
                    $runtimeRoot = Join-Path $fixture ".runtime"
                    $pythonLink = Join-Path $runtimeRoot "python"
                    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $external -Force | Out-Null
                    [System.IO.File]::WriteAllText((Join-Path $external "python.exe"), "external-python", [System.Text.Encoding]::ASCII)
                    New-Item -ItemType Junction -Path $pythonLink -Target $external | Out-Null
                    Assert-TestRequiresJunction -Path $pythonLink

                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorExactPythonVersion {
    param([string]`$PythonPath, [string]`$ProjectRoot)
    throw 'python-version-executed'
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
`$python = @(`$result.Results | Where-Object { `$_.name -eq 'python-version' })[0]
[ordered]@{
    Status = `$python.status
    Message = `$python.message
    Executed = `$python.message.Contains('python-version-executed')
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "FAIL" -Actual $state.Status -Message "Project-local Python junction should FAIL."
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $state.Message.ToLowerInvariant() -Message "Project-local Python junction failure should mention reparse points."
                    Assert-False -Condition $state.Executed -Message "Project-local Python junction must fail before executing Python."
                } finally {
                    Remove-TempFixture -Path $external
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor rejects a project-local Node runtime routed through a junction before execution"
            Body = {
                $fixture = New-DoctorFixture
                $external = New-TempFixture
                try {
                    $runtimeRoot = Join-Path $fixture ".runtime"
                    $nodeLink = Join-Path $runtimeRoot "node"
                    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
                    New-Item -ItemType Directory -Path $external -Force | Out-Null
                    [System.IO.File]::WriteAllText((Join-Path $external "node.exe"), "external-node", [System.Text.Encoding]::ASCII)
                    [System.IO.File]::WriteAllText((Join-Path $external "npm.cmd"), "@echo npm", [System.Text.Encoding]::ASCII)
                    New-Item -ItemType Junction -Path $nodeLink -Target $external | Out-Null
                    Assert-TestRequiresJunction -Path $nodeLink

                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    [pscustomobject]@{
        ExitCode = 0
        Message = 'pip check passed'
    }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    [pscustomobject]@{
        Version = '2.7.1+cpu'
        CudaBuild = `$null
        CudaAvailable = `$false
    }
}
function Get-DoctorExactNodeVersion {
    param([string]`$NodePath, [string]`$ProjectRoot)
    throw 'node-version-executed'
}
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
`$node = @(`$result.Results | Where-Object { `$_.name -eq 'node-version' })[0]
[ordered]@{
    Status = `$node.status
    Message = `$node.message
    Executed = `$node.message.Contains('node-version-executed')
} | ConvertTo-Json -Compress
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected "FAIL" -Actual $state.Status -Message "Project-local Node junction should FAIL."
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $state.Message.ToLowerInvariant() -Message "Project-local Node junction failure should mention reparse points."
                    Assert-False -Condition $state.Executed -Message "Project-local Node junction must fail before executing Node."
                } finally {
                    Remove-TempFixture -Path $external
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor rejects an external PATH Node executable leaf reparse point before execution without applying project containment"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                    $escapedFixture = $fixture.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
`$projectRoot = '$escapedFixture'
`$fakeNodePath = 'C:\external\node.exe'
`$fakeNpmPath = 'C:\external\npm.cmd'
function Get-Command {
    param([string]`$Name)
    if (`$Name -eq 'node.exe') {
        return [pscustomobject]@{ Source = `$fakeNodePath }
    }

    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}
function Test-Path {
    param([string]`$LiteralPath, [string]`$PathType)
    switch (`$LiteralPath) {
        `$fakeNodePath { return `$true }
        `$fakeNpmPath { return `$true }
        default { return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
    }
}
function Get-Item {
    param([string]`$LiteralPath, [switch]`$Force, [string]`$ErrorAction)
    if (`$LiteralPath -eq `$fakeNodePath) {
        return [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::ReparsePoint }
    }

    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function Invoke-CheckedCommand {
    param([string]`$FilePath, [string[]]`$ArgumentList)
    throw 'node-version-executed'
}
`$paths = [pscustomobject]@{
    Root = `$projectRoot
    LocalNodePath = (Join-Path `$projectRoot '.runtime\node\node.exe')
    LocalNpmPath = (Join-Path `$projectRoot '.runtime\node\npm.cmd')
}
`$manifest = [pscustomobject]@{
    runtime = [pscustomobject]@{
        node = [pscustomobject]@{ version = '24.18.0' }
    }
}
try {
    Get-DoctorNodeInfo -Paths `$paths -Manifest `$manifest | Out-Null
    throw 'Expected external PATH node reparse rejection.'
} catch {
    [ordered]@{
        Message = `$_.Exception.Message
        Executed = `$_.Exception.Message.Contains('node-version-executed')
        Containment = `$_.Exception.Message.Contains('project root')
    } | ConvertTo-Json -Compress
}
"@
                    $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                    $state = $result.StdOut | ConvertFrom-Json
                    Assert-Contains -ExpectedSubstring "reparse point" -Actual $state.Message.ToLowerInvariant() -Message "External PATH node reparse rejection should mention reparse points."
                    Assert-False -Condition $state.Executed -Message "External PATH node reparse rejection must occur before execution."
                    Assert-False -Condition $state.Containment -Message "External PATH node reparse rejection must not use project containment messaging."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor Json mode converts early fatal setup errors into one safe FAIL result with empty stderr"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    Set-Content -LiteralPath (Join-Path $fixture "scripts\config\bootstrap-manifest.json") -Value "{not-json" -Encoding ASCII
                    Set-Content -LiteralPath (Join-Path $fixture "backend\.env") -Value @(
                        "APP_MODE=local",
                        "DATABASE_URL=sqlite:///./data/local.db",
                        "JWT_SECRET_KEY=super-secret-fixture-value"
                    ) -Encoding ASCII

                    $result = Invoke-DoctorScriptProcess -ProjectRoot $fixture -ArgumentList @("-Json")
                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Doctor Json mode should return nonzero for early fatal setup errors."
                    Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Doctor Json mode should keep stderr empty for handled setup errors."

                    $json = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 1 -Actual @($json).Count -Message "Doctor Json mode should emit exactly one normalized setup result."
                    Assert-Equal -Expected "FAIL" -Actual $json[0].status -Message "Doctor Json mode setup result should FAIL."
                    Assert-True -Condition ([bool]$json[0].required) -Message "Doctor Json mode setup result should be required."
                    Assert-Contains -ExpectedSubstring "manifest" -Actual ([string]$json[0].message).ToLowerInvariant() -Message "Doctor Json mode setup result should explain the manifest failure."
                    Assert-False -Condition (($result.StdOut + $result.StdErr).Contains("super-secret-fixture-value")) -Message "Doctor Json mode setup failure leaked a secret."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor Json mode normalizes invalid Device into one safe FAIL result with empty stderr"
            Body = {
                $fixture = New-DoctorFixture
                try {
                    $result = Invoke-DoctorScriptProcess -ProjectRoot $fixture -ArgumentList @("-Json", "-Device", "bogus")
                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Doctor Json mode should return nonzero for invalid Device."
                    Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Doctor Json invalid Device should keep stderr empty."

                    $json = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 1 -Actual @($json).Count -Message "Doctor Json invalid Device should emit exactly one normalized result."
                    Assert-Equal -Expected "FAIL" -Actual $json[0].status -Message "Doctor Json invalid Device result should FAIL."
                    Assert-True -Condition ([bool]$json[0].required) -Message "Doctor Json invalid Device result should be required."
                    Assert-Contains -ExpectedSubstring "device" -Actual ([string]$json[0].message).ToLowerInvariant() -Message "Doctor Json invalid Device should mention the device category."
                    Assert-False -Condition (($result.StdOut + $result.StdErr).Contains("super-secret-fixture-value")) -Message "Doctor Json invalid Device leaked a secret."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor Json mode normalizes a missing ProjectEnvironment module into one safe FAIL result with empty stderr"
            Body = {
                $fixture = New-DoctorFixture
                $doctorRoot = Split-Path -Parent (Get-DoctorScriptPath)
                $modulePath = Join-Path $doctorRoot "lib\ProjectEnvironment.psm1"
                $backupPath = $modulePath + ".json-test-backup"
                try {
                    Move-Item -LiteralPath $modulePath -Destination $backupPath -Force
                    $result = Invoke-DoctorScriptProcess -ProjectRoot $fixture -ArgumentList @("-Json")
                    Assert-Equal -Expected 1 -Actual $result.ExitCode -Message "Doctor Json mode should return nonzero when ProjectEnvironment is missing."
                    Assert-Equal -Expected "" -Actual $result.StdErr.Trim() -Message "Doctor Json missing-module path should keep stderr empty."

                    $json = $result.StdOut | ConvertFrom-Json
                    Assert-Equal -Expected 1 -Actual @($json).Count -Message "Doctor Json missing-module path should emit exactly one normalized result."
                    Assert-Equal -Expected "FAIL" -Actual $json[0].status -Message "Doctor Json missing-module result should FAIL."
                    Assert-True -Condition ([bool]$json[0].required) -Message "Doctor Json missing-module result should be required."
                    Assert-Contains -ExpectedSubstring "module" -Actual ([string]$json[0].message).ToLowerInvariant() -Message "Doctor Json missing-module result should mention the module category."
                    Assert-False -Condition (($result.StdOut + $result.StdErr).Contains("super-secret-fixture-value")) -Message "Doctor Json missing-module path leaked a secret."
                } finally {
                    if (Test-Path -LiteralPath $backupPath) {
                        Move-Item -LiteralPath $backupPath -Destination $modulePath -Force
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Doctor sanitizes secret-bearing probe seam failures in human and JSON output"
            Body = {
                $secret = "SENTINEL-SECRET-DOCTOR"
                $cases = @(
                    [pscustomobject]@{
                        Name = "python"
                        Script = @"
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    throw 'python probe failed: SENTINEL-SECRET-DOCTOR'
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
"@
                    },
                    [pscustomobject]@{
                        Name = "node"
                        Script = @"
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    throw 'node probe failed: SENTINEL-SECRET-DOCTOR'
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    [pscustomobject]@{ ExitCode = 0; Message = 'pip check passed' }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    [pscustomobject]@{ Version = '2.7.1+cpu'; CudaBuild = `$null; CudaAvailable = `$false }
}
"@
                    },
                    [pscustomobject]@{
                        Name = "pip"
                        Script = @"
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    throw 'pip probe failed: SENTINEL-SECRET-DOCTOR'
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    [pscustomobject]@{ Version = '2.7.1+cpu'; CudaBuild = `$null; CudaAvailable = `$false }
}
"@
                    },
                    [pscustomobject]@{
                        Name = "torch"
                        Script = @"
function Get-DoctorPythonInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '3.10.11'
        Path = (Join-Path `$Paths.VenvRoot 'Scripts\python.exe')
        Source = 'backend-venv'
    }
}
function Get-DoctorNodeInfo {
    param([object]`$Paths, [object]`$Manifest)
    [pscustomobject]@{
        Version = '24.18.0'
        Path = (Join-Path `$Paths.Root '.runtime\node\node.exe')
        NpmPath = (Join-Path `$Paths.Root '.runtime\node\npm.cmd')
        Source = 'path-node'
    }
}
function Invoke-DoctorPipCheck {
    param([string]`$PythonPath, [string]`$BackendRoot)
    [pscustomobject]@{ ExitCode = 0; Message = 'pip check passed' }
}
function Get-DoctorTorchInfo {
    param([string]`$PythonPath)
    throw 'torch probe failed: SENTINEL-SECRET-DOCTOR'
}
"@
                    }
                )

                foreach ($case in $cases) {
                    $fixture = New-DoctorFixture
                    try {
                        $doctorScriptPath = (Get-DoctorScriptPath).Replace("'", "''")
                        $escapedFixture = $fixture.Replace("'", "''")
                        $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$doctorScriptPath'
function Get-DoctorSystemFacts {
    param([string]`$ProjectRoot)
    [pscustomobject]@{
        IsWindows = `$true
        Architecture = 'x64'
        FreeSpaceBytes = 20GB
    }
}
$($case.Script)
`$result = Invoke-DoctorMain -ProjectRoot '$escapedFixture' -Device auto
[ordered]@{
    Human = (Format-DoctorHumanOutput -Results `$result.Results)
    Json = (Format-DoctorJsonOutput -Results `$result.Results)
} | ConvertTo-Json -Compress
"@
                        $result = Invoke-BootstrapChildScript -ScriptContent $childScript -WorkingDirectory $fixture
                        $state = $result.StdOut | ConvertFrom-Json
                        Assert-False -Condition ($state.Human.Contains($secret)) -Message "Doctor human output leaked a secret for $($case.Name) seam."
                        Assert-False -Condition ($state.Json.Contains($secret)) -Message "Doctor JSON output leaked a secret for $($case.Name) seam."
                    } finally {
                        Remove-TempFixture -Path $fixture
                    }
                }
            }
        }
    )
}

function Invoke-BootstrapScriptTests {
    param(
        [string]$NamePattern = "*",
        [switch]$ShowProgress
    )

    $tests = @(Get-BootstrapScriptTests | Where-Object { $_.Name -like $NamePattern })
    $results = @()

    foreach ($test in $tests) {
        try {
            if ($ShowProgress) {
                Write-Host "RUN $($test.Name)"
            }
            & $test.Body
            if ($ShowProgress) {
                Write-Host "PASS $($test.Name)"
            }
            $results += [pscustomobject]@{
                Name = $test.Name
                Passed = $true
                Error = $null
            }
        } catch {
            if ($ShowProgress) {
                Write-Host "FAIL $($test.Name)"
            }
            $results += [pscustomobject]@{
                Name = $test.Name
                Passed = $false
                Error = $_.Exception.Message
            }
        }
    }

    $passed = @($results | Where-Object { $_.Passed }).Count
    $failed = @($results | Where-Object { -not $_.Passed }).Count

    return [pscustomobject]@{
        Total = $results.Count
        Passed = $passed
        Failed = $failed
        Results = $results
    }
}
