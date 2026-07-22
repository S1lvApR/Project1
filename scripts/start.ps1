[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [int]$BackendPort = 8000,
    [int]$FrontendPort = 5173,
    [int]$TimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartEnvironmentInitialized = $false

function Initialize-StartEnvironment {
    if ($script:StartEnvironmentInitialized) {
        return
    }

    $modulePath = Join-Path $PSScriptRoot "lib\ProjectEnvironment.psm1"
    $stopScriptPath = Join-Path $PSScriptRoot "stop.ps1"

    try {
        Import-Module $modulePath -Force -ErrorAction Stop
        . $stopScriptPath
        foreach ($functionName in @(
            "Assert-StopNoReparsePointTraversal",
            "ConvertTo-StopNormalizedPath",
            "Get-StopStatePath",
            "Get-StopProcessHandle",
            "New-StopQuarantinePath",
            "Read-StopStateRecord",
            "Remove-StopStateRecord",
            "Resolve-StopContainedPath",
            "Stop-ManagedRole",
            "Test-StopIntegerValue"
        )) {
            $command = Get-Command $functionName -CommandType Function -ErrorAction Stop
            Set-Item -Path ("Function:\script:{0}" -f $functionName) -Value $command.ScriptBlock
        }
    } catch {
        throw "Start environment could not be loaded."
    }

    $script:StartEnvironmentInitialized = $true
}

function Assert-StartDirectInputs {
    param(
        [Parameter(Mandatory = $true)][int]$BackendPort,
        [Parameter(Mandatory = $true)][int]$FrontendPort,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    foreach ($entry in @(
        [pscustomobject]@{ Name = "BackendPort"; Value = $BackendPort; Min = 1; Max = 65535 },
        [pscustomobject]@{ Name = "FrontendPort"; Value = $FrontendPort; Min = 1; Max = 65535 },
        [pscustomobject]@{ Name = "TimeoutSeconds"; Value = $TimeoutSeconds; Min = 1; Max = 300 }
    )) {
        if ($entry.Value -lt $entry.Min -or $entry.Value -gt $entry.Max) {
            throw "$($entry.Name) must be between $($entry.Min) and $($entry.Max)."
        }
    }

    if ($BackendPort -eq $FrontendPort) {
        throw "BackendPort and FrontendPort must be different."
    }
}

function Resolve-StartProjectRoot {
    param([AllowEmptyString()][string]$ProjectRoot)

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Join-Path $PSScriptRoot ".."
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Project root does not exist."
    }

    return $resolvedRoot
}

function Resolve-StartContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathInsideRoot -RootPath $RootPath -Path $resolvedPath)) {
        throw "$Description must stay within the project root."
    }

    return $resolvedPath
}

function Get-StartBasePythonPath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$VenvPythonPath
    )

    $venvRoot = Split-Path -Parent (Split-Path -Parent $VenvPythonPath)
    $configPath = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $venvRoot "pyvenv.cfg") -Description "Python virtual environment config"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Python virtual environment config is missing."
    }
    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $configPath

    $homeValues = @([System.IO.File]::ReadAllLines($configPath) | ForEach-Object {
            if ($_ -match '^\s*home\s*=\s*(.+?)\s*$') {
                $Matches[1]
            }
        })
    if ($homeValues.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$homeValues[0])) {
        throw "Python virtual environment config must contain exactly one home path."
    }

    $basePythonPath = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path ([string]$homeValues[0]) "python.exe") -Description "Base Python"
    Assert-StartLeafExecutable -RootPath $RootPath -Path $basePythonPath -Description "Base Python"
    return $basePythonPath
}

function Resolve-StartPaths {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $backendRoot = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "backend") -Description "Backend root"
    $frontendRoot = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "frontend") -Description "Frontend root"
    $runtimeRoot = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $RootPath ".runtime") -Description "Runtime root"
    $stateRoot = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "state") -Description "State root"
    $logsRoot = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "logs") -Description "Logs root"
    $pythonPath = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $backendRoot ".venv\Scripts\python.exe") -Description "Backend Python"
    $nodePath = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "node\node.exe") -Description "Frontend Node"
    $viteEntryPath = Resolve-StartContainedPath -RootPath $RootPath -Path (Join-Path $frontendRoot "node_modules\vite\bin\vite.js") -Description "Frontend Vite entry"

    return [pscustomobject]@{
        Root = $RootPath
        BackendRoot = $backendRoot
        FrontendRoot = $frontendRoot
        RuntimeRoot = $runtimeRoot
        StateRoot = $stateRoot
        LogsRoot = $logsRoot
        PythonPath = $pythonPath
        NodePath = $nodePath
        ViteEntryPath = $viteEntryPath
    }
}

function Assert-StartLeafExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing."
    }

    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $Path
}

function Get-StartPortStatus {
    param([Parameter(Mandatory = $true)][int]$Port)

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if (@($connections).Count -gt 0) {
        $owningProcess = @($connections | ForEach-Object { $_.OwningProcess } | Where-Object { $null -ne $_ -and [int]$_ -gt 0 } | Select-Object -First 1)
        $processId = if ($owningProcess.Count -gt 0) { [int]$owningProcess[0] } else { Get-NativeTcpListenerProcessId -Port $Port }
        return [pscustomobject]@{
            Occupied = $true
            ProcessId = $processId
        }
    }

    if (@($connections).Count -eq 0) {
        $listeners = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port })
        if ($listeners.Count -gt 0) {
            return [pscustomobject]@{
                Occupied = $true
                ProcessId = Get-NativeTcpListenerProcessId -Port $Port
            }
        }

        return [pscustomobject]@{
            Occupied = $false
            ProcessId = $null
        }
    }
}

function Invoke-StartDoctor {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [ValidateRange(1, 300)][int]$DoctorTimeoutSeconds = 30
    )

    $doctorScriptPath = Join-Path $PSScriptRoot "doctor.ps1"
    $powershellPath = Join-Path $PSHOME "powershell.exe"
    $result = Invoke-CheckedCommand -FilePath $powershellPath -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $doctorScriptPath,
        "-Device",
        "auto",
        "-Json",
        "-ProjectRoot",
        $RootPath
    ) -WorkingDirectory $RootPath -TimeoutSeconds $DoctorTimeoutSeconds

    return [pscustomobject]@{
        ExitCode = 0
        StdOut = $result.StdOut
        StdErr = $result.StdErr
    }
}

function Test-StartBackendReady {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return $true
            }
        } catch {
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Test-StartFrontendReady {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connectTask = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port)
            if ($connectTask.Wait(1000) -and $client.Connected) {
                return $true
            }
        } catch {
        } finally {
            $client.Dispose()
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function New-StartBackendCode {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )

    return "import uvicorn; from main import app; uvicorn.run(app, host='127.0.0.1', port=$Port)  # project-role-backend $ProjectRoot"
}

function New-StartFrontendCode {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$BackendPort
    )

    return @"
const { createServer } = require('vite');
(async () => {
  const server = await createServer({
    root: '.',
    configLoader: 'native',
    server: {
      host: '127.0.0.1',
      port: $Port,
      strictPort: true,
      open: false,
      proxy: {
        '/api': { target: 'http://127.0.0.1:$BackendPort' },
        '/uploads': { target: 'http://127.0.0.1:$BackendPort' }
      }
    }
  });
  await server.listen();
})();
// project-role-frontend $ProjectRoot
"@
}

function ConvertTo-StartCommandArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq "\") {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            if ($backslashCount -gt 0) {
                [void]$builder.Append("\" * ($backslashCount * 2))
                $backslashCount = 0
            }

            [void]$builder.Append('\"')
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append("\" * $backslashCount)
            $backslashCount = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append("\" * ($backslashCount * 2))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-StartLaunchSpec {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$BackendPort
    )

    $stdoutLogPath = Join-Path $Paths.LogsRoot "$Role.stdout.log"
    $stderrLogPath = Join-Path $Paths.LogsRoot "$Role.stderr.log"

    if ($Role -eq "backend") {
        $argumentList = @("-c", (New-StartBackendCode -ProjectRoot $RootPath -Port $Port))
        $filePath = $Paths.BasePythonPath
        $workingDirectory = $Paths.BackendRoot
        $environmentVariables = @{ "__PYVENV_LAUNCHER__" = $Paths.PythonPath }
    } else {
        $argumentList = @("-e", (New-StartFrontendCode -ProjectRoot $RootPath -Port $Port -BackendPort $BackendPort))
        $filePath = $Paths.NodePath
        $workingDirectory = $Paths.FrontendRoot
        $environmentVariables = @{}
    }

    $intendedCommandLine = ($filePath + " " + (@($argumentList | ForEach-Object { ConvertTo-StartCommandArgument -Argument $_ }) -join " ")).Trim()

    return [pscustomobject]@{
        Role = $Role
        FilePath = $filePath
        ArgumentList = $argumentList
        WorkingDirectory = $workingDirectory
        StdOutLogPath = $stdoutLogPath
        StdErrLogPath = $stderrLogPath
        IntendedCommandLine = $intendedCommandLine
        EnvironmentVariables = $environmentVariables
        ProjectRoot = $RootPath
        Port = $Port
    }
}

function Initialize-StartNativeLauncher {
    $typeName = New-Object System.Management.Automation.PSTypeName("Project1.Windows.DetachedProcessLauncher")
    if ($null -ne $typeName.Type) {
        return
    }

    $source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Project1.Windows
{
    public sealed class OwnedProcess : IDisposable
    {
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 0x00000102;
        private const uint WAIT_FAILED = 0xFFFFFFFF;
        private IntPtr handle;

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        internal OwnedProcess(IntPtr processHandle, int processId)
        {
            handle = processHandle;
            Id = processId;
        }

        public int Id { get; private set; }

        public bool HasExited
        {
            get
            {
                IntPtr current = GetHandle();
                uint result = WaitForSingleObject(current, 0);
                if (result == WAIT_FAILED) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not query process state.");
                return result == WAIT_OBJECT_0;
            }
        }

        public void Kill()
        {
            if (!TerminateProcess(GetHandle(), 1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not terminate process.");
        }

        public bool WaitForExit(int milliseconds)
        {
            uint result = WaitForSingleObject(GetHandle(), checked((uint)milliseconds));
            if (result == WAIT_FAILED) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not wait for process exit.");
            return result == WAIT_OBJECT_0;
        }

        public void Refresh()
        {
            GetHandle();
        }

        public void Dispose()
        {
            IntPtr current = Interlocked.Exchange(ref handle, IntPtr.Zero);
            if (current != IntPtr.Zero) CloseHandle(current);
            GC.SuppressFinalize(this);
        }

        ~OwnedProcess()
        {
            Dispose();
        }

        private IntPtr GetHandle()
        {
            IntPtr current = handle;
            if (current == IntPtr.Zero) throw new ObjectDisposedException("OwnedProcess");
            return current;
        }
    }

    public static class DetachedProcessLauncher
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint CREATE_ALWAYS = 2;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint STARTF_USESHOWWINDOW = 0x00000001;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const short SW_HIDE = 0;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = new IntPtr(0x00020002);
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES attributes, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnedSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static OwnedProcess Launch(string filePath, string arguments, string workingDirectory, string stdoutPath, string stderrPath)
        {
            SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.bInheritHandle = true;

            IntPtr stdin = INVALID_HANDLE_VALUE;
            IntPtr stdout = INVALID_HANDLE_VALUE;
            IntPtr stderr = INVALID_HANDLE_VALUE;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();

            try
            {
                stdin = CreateFileW("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                stdout = CreateFileW(stdoutPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                stderr = CreateFileW(stderrPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                if (stdin == INVALID_HANDLE_VALUE || stdout == INVALID_HANDLE_VALUE || stderr == INVALID_HANDLE_VALUE)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open detached process standard handles.");

                IntPtr attributeSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeSize);
                attributeList = Marshal.AllocHGlobal(attributeSize);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeSize))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not initialize process handle inheritance.");

                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, stdin);
                Marshal.WriteIntPtr(handleList, IntPtr.Size, stdout);
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderr);
                if (!UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList, new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restrict inherited process handles.");

                STARTUPINFOEX startup = new STARTUPINFOEX();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                startup.StartupInfo.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
                startup.StartupInfo.wShowWindow = SW_HIDE;
                startup.StartupInfo.hStdInput = stdin;
                startup.StartupInfo.hStdOutput = stdout;
                startup.StartupInfo.hStdError = stderr;
                startup.lpAttributeList = attributeList;

                string executable = filePath.Contains(" ") ? "\"" + filePath + "\"" : filePath;
                StringBuilder commandLine = new StringBuilder((executable + " " + arguments).Trim());
                if (!CreateProcessW(filePath, commandLine, IntPtr.Zero, IntPtr.Zero, true, EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, IntPtr.Zero, workingDirectory, ref startup, out processInfo))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create detached process.");

                OwnedProcess owned = new OwnedProcess(processInfo.hProcess, checked((int)processInfo.dwProcessId));
                processInfo.hProcess = IntPtr.Zero;
                return owned;
            }
            finally
            {
                if (processInfo.hThread != IntPtr.Zero) CloseHandle(processInfo.hThread);
                if (processInfo.hProcess != IntPtr.Zero) CloseHandle(processInfo.hProcess);
                if (attributeList != IntPtr.Zero) { DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
                if (stdin != INVALID_HANDLE_VALUE) CloseHandle(stdin);
                if (stdout != INVALID_HANDLE_VALUE) CloseHandle(stdout);
                if (stderr != INVALID_HANDLE_VALUE) CloseHandle(stderr);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Start-ManagedProcess {
    param([Parameter(Mandatory = $true)]$LaunchSpec)

    $arguments = @($LaunchSpec.ArgumentList | ForEach-Object { ConvertTo-StartCommandArgument -Argument $_ }) -join " "
    Initialize-StartNativeLauncher
    $environmentVariables = if ($null -ne $LaunchSpec.PSObject.Properties["EnvironmentVariables"] -and $null -ne $LaunchSpec.EnvironmentVariables) {
        $LaunchSpec.EnvironmentVariables
    } else {
        @{}
    }
    $previousEnvironment = @{}
    try {
        foreach ($entry in $environmentVariables.GetEnumerator()) {
            $name = [string]$entry.Key
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains("=")) {
                throw "Managed process environment variable name is invalid."
            }
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, "Process")
        }

        $process = [Project1.Windows.DetachedProcessLauncher]::Launch(
            [string]$LaunchSpec.FilePath,
            [string]$arguments,
            [string]$LaunchSpec.WorkingDirectory,
            [string]$LaunchSpec.StdOutLogPath,
            [string]$LaunchSpec.StdErrLogPath
        )
    } finally {
        foreach ($entry in $previousEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
        }
    }

    return [pscustomobject]@{
        Process = $process
        IntendedCommandLine = $LaunchSpec.IntendedCommandLine
        StdOutLogPath = $LaunchSpec.StdOutLogPath
        StdErrLogPath = $LaunchSpec.StdErrLogPath
    }
}

function Write-StartStateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)]$Record,
        [scriptblock]$MoveAction = { param($LiteralPath, $Destination) Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop }
    )

    $statePath = Get-StopStatePath -RootPath $RootPath -Role $Role
    $stateDirectory = Split-Path -Parent $statePath
    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $stateDirectory
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $stateDirectory

    $tempPath = Join-Path $stateDirectory "$Role.$([System.Guid]::NewGuid().ToString('N')).tmp"
    $resolvedTempPath = Resolve-StartContainedPath -RootPath $RootPath -Path $tempPath -Description "Temporary state record"
    $finalPath = Resolve-StartContainedPath -RootPath $RootPath -Path $statePath -Description "Final state record"

    try {
        $json = $Record | ConvertTo-Json -Depth 6 -Compress
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($resolvedTempPath, $json, $utf8NoBom)
        Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $resolvedTempPath
        & $MoveAction $resolvedTempPath $finalPath
    } catch {
        if (Test-Path -LiteralPath $resolvedTempPath -PathType Leaf) {
            Remove-Item -LiteralPath $resolvedTempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    return $finalPath
}

function New-StartStateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)]$ProcessHandle,
        [Parameter(Mandatory = $true)][string]$IntendedCommandLine,
        [Parameter(Mandatory = $true)][scriptblock]$IdentityProvider
    )

    $identity = & $IdentityProvider $ProcessHandle $IntendedCommandLine
    $executablePath = [string]$identity.ExecutablePath
    $commandLine = [string]$identity.CommandLine
    $projectRoot = [string]$RootPath
    $roleValue = [string]$Role

    foreach ($entry in @(
        [pscustomobject]@{ Name = "executablePath"; Value = $executablePath },
        [pscustomobject]@{ Name = "commandLine"; Value = $commandLine },
        [pscustomobject]@{ Name = "projectRoot"; Value = $projectRoot },
        [pscustomobject]@{ Name = "role"; Value = $roleValue }
    )) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) {
            throw "Start state record $($entry.Name) must not be empty."
        }
    }

    $roleMarker = "project-role-$Role"
    if ($commandLine.IndexOf($RootPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $commandLine.IndexOf($roleMarker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Started process identity does not match the project role."
    }

    return [ordered]@{
        schemaVersion = [int]1
        pid = [int]$identity.Pid
        executablePath = $executablePath
        startTimeUtc = ([datetime]$identity.StartTimeUtc).ToUniversalTime().ToString("o")
        commandLine = $commandLine
        projectRoot = $projectRoot
        role = $roleValue
    }
}

function Remove-StartOwnedStateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)]$Record
    )

    $statePath = Get-StopStatePath -RootPath $RootPath -Role $Role
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return
    }

    try {
        $current = Read-StopStateRecord -StatePath $statePath -Role $Role -ProjectRoot $RootPath
    } catch {
        return
    }

    if ([int]$current.pid -ne [int]$Record.pid) {
        return
    }

    if (-not ([string]$current.startTimeUtc).Equals([string]$Record.startTimeUtc, [System.StringComparison]::Ordinal)) {
        return
    }

    Remove-StopStateRecord -RootPath $RootPath -StatePath $statePath
}

function Stop-StartedProcessHandle {
    param(
        [Parameter(Mandatory = $true)]$Started,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    if ($null -eq $Started -or $null -eq $Started.Process) {
        throw "Launched process handle is unavailable."
    }

    $process = $Started.Process
    try {
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                throw "Timed out waiting for the launched process to exit."
            }
        }

        $process.Refresh()
        if (-not $process.HasExited) {
            throw "Launched process is still running after termination."
        }
    } catch {
        throw "Failed to stop launched process: $($_.Exception.Message)"
    } finally {
        $process.Dispose()
    }
}

function Get-StartExistingRoleState {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role
    )

    $statePath = Get-StopStatePath -RootPath $RootPath -Role $Role
    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $statePath

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    return Read-StopStateRecord -StatePath $statePath -Role $Role -ProjectRoot $RootPath
}

function Test-StartExistingRoleMatch {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)]$StateRecord,
        [Parameter(Mandatory = $true)]$PortStatus,
        [Parameter(Mandatory = $true)][scriptblock]$ReadyWaiter,
        [Parameter(Mandatory = $true)][scriptblock]$IdentityProvider,
        [Parameter(Mandatory = $true)][int]$Port,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    if ($null -eq $PortStatus.ProcessId) {
        return $false
    }

    if ([int]$PortStatus.ProcessId -ne [int]$StateRecord.pid) {
        return $false
    }

    $process = Get-StopProcessHandle -ProcessId $StateRecord.pid
    if ($null -eq $process) {
        return $false
    }

    try {
        $actualIdentity = & $IdentityProvider $process
        if ([int]$StateRecord.pid -ne [int]$actualIdentity.Pid) {
            return $false
        }

        if (-not ([System.IO.Path]::GetFullPath([string]$StateRecord.executablePath)).Equals([System.IO.Path]::GetFullPath([string]$actualIdentity.ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        $recordedStart = [datetime]::Parse([string]$StateRecord.startTimeUtc, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
        if ($recordedStart -ne ([datetime]$actualIdentity.StartTimeUtc).ToUniversalTime()) {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace([string]$actualIdentity.CommandLine) -or
            -not ([string]$StateRecord.commandLine).Equals([string]$actualIdentity.CommandLine, [System.StringComparison]::Ordinal)) {
            return $false
        }

        $roleMarker = "project-role-$Role"
        if ($StateRecord.commandLine.IndexOf($RootPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $StateRecord.commandLine.IndexOf($roleMarker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return $false
        }

        if ($actualIdentity.CommandLine.IndexOf($RootPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $actualIdentity.CommandLine.IndexOf($roleMarker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return $false
        }

        return [bool](& $ReadyWaiter ([pscustomobject]@{
            RootPath = $RootPath
            Role = $Role
            Port = $Port
            TimeoutSeconds = $TimeoutSeconds
            Process = $process
            Record = $StateRecord
        }))
    } finally {
        $process.Dispose()
    }
}

function Assert-StartLaunchedOwnership {
    param(
        [Parameter(Mandatory = $true)]$StartedEntry,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][scriptblock]$PortStatusProvider
    )

    if ($null -eq $StartedEntry.Launch.Process -or $StartedEntry.Launch.Process.HasExited) {
        throw "$Role ownership check failed because the launched process exited."
    }

    $portStatus = & $PortStatusProvider $Port
    if ($null -eq $portStatus -or -not $portStatus.Occupied -or $null -eq $portStatus.ProcessId -or
        [int]$portStatus.ProcessId -ne [int]$StartedEntry.Record.pid) {
        throw "$Role ownership check failed for port $Port."
    }
}

function Invoke-StartMain {
    param(
        [string]$ProjectRoot,
        [int]$BackendPort = 8000,
        [int]$FrontendPort = 5173,
        [int]$TimeoutSeconds = 90,
        [scriptblock]$DoctorRunner = { param($RootPath, $DoctorTimeoutSeconds) Invoke-StartDoctor -RootPath $RootPath -DoctorTimeoutSeconds $DoctorTimeoutSeconds },
        [scriptblock]$PortStatusProvider = { param($Port) Get-StartPortStatus -Port $Port },
        [scriptblock]$ProcessLauncher = { param($LaunchSpec) Start-ManagedProcess -LaunchSpec $LaunchSpec },
        [scriptblock]$ProcessIdentityProvider = { param($ProcessHandle) Get-ProjectProcessIdentity -ProcessId $ProcessHandle.Id },
        [scriptblock]$ExistingIdentityProvider = { param($ProcessHandle) Get-ProjectProcessIdentity -ProcessId $ProcessHandle.Id },
        [scriptblock]$PostStartPortStatusProvider = { param($Port) Get-StartPortStatus -Port $Port },
        [scriptblock]$ProcessStopper = { param($Started, $StopTimeoutSeconds) Stop-StartedProcessHandle -Started $Started -TimeoutSeconds $StopTimeoutSeconds },
        [scriptblock]$BackendReadyWaiter = { param($ReadySpec) Test-StartBackendReady -Port $ReadySpec.Port -TimeoutSeconds $ReadySpec.TimeoutSeconds },
        [scriptblock]$FrontendReadyWaiter = { param($ReadySpec) Test-StartFrontendReady -Port $ReadySpec.Port -TimeoutSeconds $ReadySpec.TimeoutSeconds }
    )

    Assert-StartDirectInputs -BackendPort $BackendPort -FrontendPort $FrontendPort -TimeoutSeconds $TimeoutSeconds
    Initialize-StartEnvironment

    $resolvedRoot = Resolve-StartProjectRoot -ProjectRoot $ProjectRoot
    $doctorTimeoutSeconds = [Math]::Min([Math]::Max($TimeoutSeconds, 1), 30)
    $doctorResult = & $DoctorRunner $resolvedRoot $doctorTimeoutSeconds
    if ($null -eq $doctorResult -or [int]$doctorResult.ExitCode -ne 0) {
        throw "Doctor failed."
    }

    $paths = Resolve-StartPaths -RootPath $resolvedRoot
    foreach ($path in @($paths.RuntimeRoot, $paths.StateRoot, $paths.LogsRoot)) {
        Assert-StopNoReparsePointTraversal -RootPath $resolvedRoot -Path $path
    }

    Assert-StartLeafExecutable -RootPath $resolvedRoot -Path $paths.PythonPath -Description "Backend Python"
    $basePythonPath = Get-StartBasePythonPath -RootPath $resolvedRoot -VenvPythonPath $paths.PythonPath
    $paths | Add-Member -NotePropertyName BasePythonPath -NotePropertyValue $basePythonPath
    Assert-StartLeafExecutable -RootPath $resolvedRoot -Path $paths.NodePath -Description "Frontend Node"
    Assert-StartLeafExecutable -RootPath $resolvedRoot -Path $paths.ViteEntryPath -Description "Frontend Vite entry"

    $existingBackendState = Get-StartExistingRoleState -RootPath $resolvedRoot -Role backend
    $existingFrontendState = Get-StartExistingRoleState -RootPath $resolvedRoot -Role frontend
    $backendStatus = & $PortStatusProvider $BackendPort
    $frontendStatus = & $PortStatusProvider $FrontendPort

    foreach ($roleState in @(
        [pscustomobject]@{ Role = "backend"; State = $existingBackendState; PortStatus = $backendStatus },
        [pscustomobject]@{ Role = "frontend"; State = $existingFrontendState; PortStatus = $frontendStatus }
    )) {
        if (-not $roleState.PortStatus.Occupied -and $null -ne $roleState.State) {
            $recordedProcess = Get-StopProcessHandle -ProcessId $roleState.State.pid
            if ($null -ne $recordedProcess) {
                $recordedProcess.Dispose()
                throw "$($roleState.Role) recorded process is still running while its port is not listening."
            }

            $staleStatePath = Get-StopStatePath -RootPath $resolvedRoot -Role $roleState.Role
            Remove-StopStateRecord -RootPath $resolvedRoot -StatePath $staleStatePath
        }
    }

    if ($backendStatus.Occupied -or $frontendStatus.Occupied) {
        $backendMatches = $false
        $frontendMatches = $false

        if ($backendStatus.Occupied -and $null -ne $existingBackendState) {
            $backendMatches = Test-StartExistingRoleMatch -RootPath $resolvedRoot -Role backend -StateRecord $existingBackendState -PortStatus $backendStatus -ReadyWaiter $BackendReadyWaiter -IdentityProvider $ExistingIdentityProvider -Port $BackendPort -TimeoutSeconds $TimeoutSeconds
        }

        if ($frontendStatus.Occupied -and $null -ne $existingFrontendState) {
            $frontendMatches = Test-StartExistingRoleMatch -RootPath $resolvedRoot -Role frontend -StateRecord $existingFrontendState -PortStatus $frontendStatus -ReadyWaiter $FrontendReadyWaiter -IdentityProvider $ExistingIdentityProvider -Port $FrontendPort -TimeoutSeconds $TimeoutSeconds
        }

        if ($backendStatus.Occupied -and $frontendStatus.Occupied -and $backendMatches -and $frontendMatches) {
            $frontendUrl = "http://127.0.0.1:$FrontendPort"
            $backendDocsUrl = "http://127.0.0.1:$BackendPort/docs"
            return [pscustomobject]@{
                FrontendUrl = $frontendUrl
                BackendDocsUrl = $backendDocsUrl
                Messages = @(
                    "backend already running at $backendDocsUrl",
                    "frontend already running at $frontendUrl",
                    "backend logs: $(Join-Path $paths.LogsRoot 'backend.stdout.log')",
                    "frontend logs: $(Join-Path $paths.LogsRoot 'frontend.stdout.log')"
                )
            }
        }

        if ($backendStatus.Occupied) {
            throw "backend port is occupied."
        }

        throw "frontend port is occupied."
    }

    New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $paths.LogsRoot -Force | Out-Null
    Assert-StopNoReparsePointTraversal -RootPath $resolvedRoot -Path $paths.StateRoot
    Assert-StopNoReparsePointTraversal -RootPath $resolvedRoot -Path $paths.LogsRoot

    $started = New-Object System.Collections.Generic.List[object]
    $launchSpecs = @(
        (New-StartLaunchSpec -RootPath $resolvedRoot -Paths $paths -Role backend -Port $BackendPort -BackendPort $BackendPort),
        (New-StartLaunchSpec -RootPath $resolvedRoot -Paths $paths -Role frontend -Port $FrontendPort -BackendPort $BackendPort)
    )
    foreach ($launchSpec in $launchSpecs) {
        foreach ($logPath in @($launchSpec.StdOutLogPath, $launchSpec.StdErrLogPath)) {
            $resolvedLogPath = Resolve-StartContainedPath -RootPath $resolvedRoot -Path $logPath -Description "Process log"
            Assert-StopNoReparsePointTraversal -RootPath $resolvedRoot -Path $resolvedLogPath
        }
    }

    try {
        foreach ($launchSpec in $launchSpecs) {
            $launchResult = & $ProcessLauncher $launchSpec
            $startedEntry = [pscustomobject]@{
                Role = $launchSpec.Role
                Launch = $launchResult
                Record = $null
            }
            $started.Add($startedEntry)

            $record = New-StartStateRecord -RootPath $resolvedRoot -Role $launchSpec.Role -ProcessHandle $launchResult.Process -IntendedCommandLine ([string]$launchResult.IntendedCommandLine) -IdentityProvider $ProcessIdentityProvider
            [void](Write-StartStateRecord -RootPath $resolvedRoot -Role $launchSpec.Role -Record $record)
            $startedEntry.Record = $record
        }

        if (-not [bool](& $BackendReadyWaiter ([pscustomobject]@{
                    RootPath = $resolvedRoot
                    Role = "backend"
                    Port = $BackendPort
                    TimeoutSeconds = $TimeoutSeconds
                }))) {
            throw "backend readiness failed for backend."
        }
        $backendEntry = @($started.ToArray() | Where-Object { $_.Role -eq "backend" })[0]
        Assert-StartLaunchedOwnership -StartedEntry $backendEntry -Role backend -Port $BackendPort -PortStatusProvider $PostStartPortStatusProvider

        if (-not [bool](& $FrontendReadyWaiter ([pscustomobject]@{
                    RootPath = $resolvedRoot
                    Role = "frontend"
                    Port = $FrontendPort
                    TimeoutSeconds = $TimeoutSeconds
                }))) {
            throw "frontend readiness failed for frontend."
        }
        $frontendEntry = @($started.ToArray() | Where-Object { $_.Role -eq "frontend" })[0]
        Assert-StartLaunchedOwnership -StartedEntry $frontendEntry -Role frontend -Port $FrontendPort -PortStatusProvider $PostStartPortStatusProvider
    } catch {
        $caughtError = $_
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        $cleanupEntries = @($started.ToArray())
        [array]::Reverse($cleanupEntries)
        foreach ($entry in $cleanupEntries) {
            try {
                & $ProcessStopper $entry.Launch $TimeoutSeconds
                if ($null -ne $entry.Record) {
                    Remove-StartOwnedStateRecord -RootPath $resolvedRoot -Role $entry.Role -Record $entry.Record
                }
            } catch {
                $cleanupErrors.Add("$($entry.Role): $($_.Exception.Message)")
            }
        }

        if ($cleanupErrors.Count -gt 0) {
            throw "Start failed: $($caughtError.Exception.Message) Cleanup failed: $($cleanupErrors -join '; ')"
        }
        throw $caughtError
    }

    foreach ($entry in $started.ToArray()) {
        try {
            $entry.Launch.Process.Dispose()
        } catch {
        }
    }

    $frontendUrl = "http://127.0.0.1:$FrontendPort"
    $backendDocsUrl = "http://127.0.0.1:$BackendPort/docs"
    return [pscustomobject]@{
        FrontendUrl = $frontendUrl
        BackendDocsUrl = $backendDocsUrl
        Messages = @(
            "frontend: $frontendUrl",
            "backend docs: $backendDocsUrl",
            "backend stdout log: $(Join-Path $paths.LogsRoot 'backend.stdout.log')",
            "backend stderr log: $(Join-Path $paths.LogsRoot 'backend.stderr.log')",
            "frontend stdout log: $(Join-Path $paths.LogsRoot 'frontend.stdout.log')",
            "frontend stderr log: $(Join-Path $paths.LogsRoot 'frontend.stderr.log')"
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-StartMain -ProjectRoot $ProjectRoot -BackendPort $BackendPort -FrontendPort $FrontendPort -TimeoutSeconds $TimeoutSeconds
        foreach ($message in @($result.Messages)) {
            Write-Output $message
        }
        exit 0
    } catch {
        Write-Output "start: $($_.Exception.Message)"
        exit 1
    }
}
