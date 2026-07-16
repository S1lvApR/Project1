Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-RequiredManifestValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $value = Get-ObjectPropertyValue -Object $Object -Name $Name
    if ($null -eq $value) {
        throw "Missing required bootstrap manifest field: $Context.$Name"
    }

    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required bootstrap manifest field: $Context.$Name"
    }

    return $value
}

function Get-RequiredManifestString {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $value = Get-RequiredManifestValue -Object $Object -Name $Name -Context $Context
    if (-not ($value -is [string])) {
        throw "Invalid bootstrap manifest field: $Context.$Name must be a string."
    }

    return $value
}

function Assert-LeafFilename {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $isDotSegment = $Value -eq "." -or $Value -eq ".."
    $hasInvalidCharacter = $Value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0
    $normalizedValue = $Value.TrimEnd([char[]]@(" ", "."))
    $extensionIndex = $normalizedValue.IndexOf(".")
    $baseName = if ($extensionIndex -ge 0) {
        $normalizedValue.Substring(0, $extensionIndex)
    } else {
        $normalizedValue
    }
    $normalizedBaseName = $baseName.TrimEnd().ToUpperInvariant()
    $isReservedDeviceName = $normalizedBaseName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'

    if ($isDotSegment -or [System.IO.Path]::IsPathRooted($Value) -or $hasInvalidCharacter -or $isReservedDeviceName) {
        throw "Invalid bootstrap manifest field: $Context must be a leaf filename."
    }
}

function Assert-NumericDottedVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -notmatch '^\d+(?:\.\d+)+$') {
        throw "Invalid bootstrap manifest field: $Context must be a numeric dotted version."
    }
}

function Assert-HttpsUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri) -or
        -not $uri.Scheme.Equals("https", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid bootstrap manifest field: $Context must be an HTTPS URL."
    }
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Invalid bootstrap manifest field: $Context must be exactly 64 hexadecimal characters."
    }
}

function Assert-PositiveInteger {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $integerTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64]
    )
    if ($integerTypes -notcontains $Value.GetType() -or $Value -le 0) {
        throw "Invalid bootstrap manifest field: $Context must be a positive integer."
    }
}

function ConvertTo-VersionSegments {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "Version must not be empty."
    }

    $segments = @()
    foreach ($segment in $Version.Trim().Split(".")) {
        if ($segment -notmatch "^\d+$") {
            throw "Invalid version segment '$segment' in version '$Version'."
        }

        $segments += [int]$segment
    }

    return $segments
}

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.Length -gt 3 -and ($fullPath.EndsWith("\") -or $fullPath.EndsWith("/"))) {
        return $fullPath.TrimEnd("\", "/")
    }

    return $fullPath
}

function Get-ProcessRecord {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $filter = "ProcessId = $ProcessId"

    try {
        return Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop
    } catch {
        try {
            return Get-WmiObject Win32_Process -Filter $filter -ErrorAction Stop
        } catch {
            return $null
        }
    }
}

function Get-IdentityValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime()
    }

    return ([datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime()
}

function ConvertTo-WindowsCommandArgument {
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

function Test-KnownDeviceMode {
    param([Parameter(Mandatory = $true)][string]$Mode)

    return @("auto", "cpu", "gpu") -contains $Mode
}

function Get-ProjectRoot {
    return $script:ProjectRoot
}

function Read-BootstrapManifest {
    param(
        [string]$Path = (Join-Path (Get-ProjectRoot) "scripts\config\bootstrap-manifest.json")
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $manifest = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json

    $schemaVersion = Get-RequiredManifestValue -Object $manifest -Name "schemaVersion" -Context "manifest"
    if ([int]$schemaVersion -ne 1) {
        throw "Unsupported bootstrap manifest schemaVersion: $schemaVersion"
    }

    $runtime = Get-RequiredManifestValue -Object $manifest -Name "runtime" -Context "manifest"
    foreach ($runtimeName in @("python", "node")) {
        $runtimeRecord = Get-RequiredManifestValue -Object $runtime -Name $runtimeName -Context "runtime"
        $context = "runtime.$runtimeName"
        $version = Get-RequiredManifestString -Object $runtimeRecord -Name "version" -Context $context
        $filename = Get-RequiredManifestString -Object $runtimeRecord -Name "filename" -Context $context
        $url = Get-RequiredManifestString -Object $runtimeRecord -Name "url" -Context $context
        $sha256 = Get-RequiredManifestString -Object $runtimeRecord -Name "sha256" -Context $context
        Assert-LeafFilename -Value $filename -Context "$context.filename"
        Assert-NumericDottedVersion -Value $version -Context "$context.version"
        Assert-HttpsUrl -Value $url -Context "$context.url"
        Assert-Sha256 -Value $sha256 -Context "$context.sha256"
    }

    $release = Get-RequiredManifestValue -Object $manifest -Name "release" -Context "manifest"
    $repository = Get-RequiredManifestString -Object $release -Name "repository" -Context "release"
    $tag = Get-RequiredManifestString -Object $release -Name "tag" -Context "release"
    $models = Get-RequiredManifestValue -Object $release -Name "models" -Context "release"
    foreach ($model in @($models)) {
        $context = "release.models[]"
        $filename = Get-RequiredManifestString -Object $model -Name "filename" -Context $context
        $bytes = Get-RequiredManifestValue -Object $model -Name "bytes" -Context $context
        $sha256 = Get-RequiredManifestString -Object $model -Name "sha256" -Context $context
        $url = Get-RequiredManifestString -Object $model -Name "url" -Context $context
        foreach ($field in @("source", "license", "purpose")) {
            [void](Get-RequiredManifestString -Object $model -Name $field -Context $context)
        }

        Assert-LeafFilename -Value $filename -Context "$context.filename"
        Assert-PositiveInteger -Value $bytes -Context "$context.bytes"
        Assert-Sha256 -Value $sha256 -Context "$context.sha256"
        Assert-HttpsUrl -Value $url -Context "$context.url"
        $expectedUrl = "https://github.com/$repository/releases/download/$tag/$filename"
        if (-not $url.Equals($expectedUrl, [System.StringComparison]::Ordinal)) {
            throw "Invalid bootstrap manifest field: $context.url must equal '$expectedUrl'."
        }
    }

    return $manifest
}

function Compare-Version {
    param(
        [Parameter(Mandatory = $true)][string]$LeftVersion,
        [Parameter(Mandatory = $true)][string]$RightVersion
    )

    $leftSegments = ConvertTo-VersionSegments -Version $LeftVersion
    $rightSegments = ConvertTo-VersionSegments -Version $RightVersion
    $count = [Math]::Max($leftSegments.Count, $rightSegments.Count)

    for ($index = 0; $index -lt $count; $index++) {
        $left = if ($index -lt $leftSegments.Count) { $leftSegments[$index] } else { 0 }
        $right = if ($index -lt $rightSegments.Count) { $rightSegments[$index] } else { 0 }

        if ($left -gt $right) {
            return 1
        }

        if ($left -lt $right) {
            return -1
        }
    }

    return 0
}

function Test-VersionAtLeast {
    param(
        [Parameter(Mandatory = $true)][string]$ActualVersion,
        [Parameter(Mandatory = $true)][string]$MinimumVersion
    )

    return (Compare-Version -LeftVersion $ActualVersion -RightVersion $MinimumVersion) -ge 0
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fileHash = Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop
    } catch {
        throw "Unable to calculate SHA256 for '$Path': $($_.Exception.Message)"
    }

    return $fileHash.Hash.ToUpperInvariant()
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $expected = $ExpectedSha256.Trim().ToUpperInvariant()
    $actual = Get-FileSha256 -Path $Path
    if ($expected -ne $actual) {
        throw "File SHA256 mismatch for '$Path'. Expected: $expected. Actual: $actual."
    }
}

function Resolve-DeviceMode {
    param(
        [Parameter(Mandatory = $true)][string]$RequestedMode,
        [Parameter(Mandatory = $true)][bool]$HasNvidia
    )

    $mode = $RequestedMode.Trim().ToLowerInvariant()
    switch ($mode) {
        "cpu" { return "cpu" }
        "auto" { if ($HasNvidia) { return "gpu" } else { return "cpu" } }
        "gpu" {
            if (-not $HasNvidia) {
                throw "GPU mode requires Nvidia support."
            }

            return "gpu"
        }
        default {
            throw "Unsupported device mode: $RequestedMode"
        }
    }
}

function New-SecureToken {
    param([ValidateRange(1, 4096)][int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    return ([System.BitConverter]::ToString($bytes)).Replace("-", "")
}

function New-LocalEnvContent {
    param(
        [Alias("Secret")]
        [Parameter(Mandatory = $true)][string]$JwtSecretKey,
        [Parameter(Mandatory = $true)][string]$YoloDevice,
        [Parameter(Mandatory = $true)][string]$GtsrbDevice,
        [string]$TemplatePath = (Join-Path $PSScriptRoot "..\..\backend\.env.local.example")
    )

    if ([string]::IsNullOrWhiteSpace($JwtSecretKey)) {
        throw "JwtSecretKey must not be empty."
    }

    $normalizedYoloDevice = $YoloDevice.Trim().ToLowerInvariant()
    $normalizedGtsrbDevice = $GtsrbDevice.Trim().ToLowerInvariant()
    if (-not (Test-KnownDeviceMode -Mode $normalizedYoloDevice)) {
        throw "Unsupported YOLO device mode: $YoloDevice"
    }

    if (-not (Test-KnownDeviceMode -Mode $normalizedGtsrbDevice)) {
        throw "Unsupported GTSRB device mode: $GtsrbDevice"
    }

    $resolvedTemplatePath = [System.IO.Path]::GetFullPath($TemplatePath)
    if (-not (Test-Path -LiteralPath $resolvedTemplatePath -PathType Leaf)) {
        throw "Local environment template is missing: $resolvedTemplatePath"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $seenKeys = @{}
    foreach ($rawLine in [System.IO.File]::ReadAllLines($resolvedTemplatePath, [System.Text.Encoding]::UTF8)) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            throw "Invalid local environment template line: $line"
        }

        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1)
        if ($seenKeys.ContainsKey($key)) {
            throw "Duplicate local environment template key: $key"
        }
        $seenKeys[$key] = $true

        switch ($key) {
            "YOLO_DEVICE" { $value = $normalizedYoloDevice }
            "GTSRB_DEVICE" { $value = $normalizedGtsrbDevice }
            "JWT_SECRET_KEY" {
                if ($value -ne "generated-by-bootstrap") {
                    throw "JWT_SECRET_KEY template value must be generated-by-bootstrap."
                }
                $value = $JwtSecretKey
            }
        }
        $lines.Add("$key=$value")
    }

    foreach ($requiredKey in @("YOLO_DEVICE", "GTSRB_DEVICE", "JWT_SECRET_KEY")) {
        if (-not $seenKeys.ContainsKey($requiredKey)) {
            throw "Local environment template is missing $requiredKey."
        }
    }

    return ($lines.ToArray() -join "`r`n") + "`r`n"
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normalizedRoot = ConvertTo-NormalizedPath -Path $RootPath
    $candidatePath = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidatePath)) {
        $candidatePath = Join-Path $normalizedRoot $candidatePath
    }

    $normalizedCandidate = ConvertTo-NormalizedPath -Path $candidatePath
    if ($normalizedCandidate.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $normalizedCandidate.StartsWith($normalizedRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Initialize-ProjectProcessNativeMethods {
    $typeName = New-Object System.Management.Automation.PSTypeName("Project1.Windows.ProcessIntrospection")
    if ($null -ne $typeName.Type) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Runtime.InteropServices;

namespace Project1.Windows
{
    public static class ProcessIntrospection
    {
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const int PROCESS_COMMAND_LINE_INFORMATION = 60;
        private const int AF_INET = 2;
        private const int TCP_TABLE_OWNER_PID_LISTENER = 3;
        private const uint ERROR_INSUFFICIENT_BUFFER = 122;
        private const uint TH32CS_SNAPPROCESS = 0x00000002;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = 9;
        private const int MAX_PATH = 260;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MAX_PATH)]
            public string szExeFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct UNICODE_STRING
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MIB_TCPROW_OWNER_PID
        {
            public uint State;
            public uint LocalAddress;
            public uint LocalPort;
            public uint RemoteAddress;
            public uint RemotePort;
            public uint OwningPid;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint processAccess, bool inheritHandle, int processId);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(
            IntPtr processHandle,
            int processInformationClass,
            IntPtr processInformation,
            int processInformationLength,
            out int returnLength);

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(
            IntPtr tcpTable,
            ref int size,
            bool order,
            int ipVersion,
            int tableClass,
            uint reserved);

        public static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                return IntPtr.Zero;
            }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int informationLength = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr informationPointer = Marshal.AllocHGlobal(informationLength);
            try
            {
                Marshal.StructureToPtr(information, informationPointer, false);
                if (!SetInformationJobObject(
                    job,
                    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
                    informationPointer,
                    unchecked((uint)informationLength)))
                {
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
                return job;
            }
            finally
            {
                Marshal.FreeHGlobal(informationPointer);
            }
        }

        public static bool AssignToJob(IntPtr job, IntPtr process)
        {
            return job != IntPtr.Zero && process != IntPtr.Zero && AssignProcessToJobObject(job, process);
        }

        public static void CloseJob(IntPtr job)
        {
            if (job != IntPtr.Zero)
            {
                CloseHandle(job);
            }
        }

        public static int[] GetDescendantProcessIds(int rootProcessId)
        {
            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == new IntPtr(-1))
            {
                return new int[0];
            }

            var children = new Dictionary<int, List<int>>();
            try
            {
                PROCESSENTRY32 entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (Process32FirstW(snapshot, ref entry))
                {
                    do
                    {
                        int parentId = unchecked((int)entry.th32ParentProcessID);
                        int processId = unchecked((int)entry.th32ProcessID);
                        List<int> childIds;
                        if (!children.TryGetValue(parentId, out childIds))
                        {
                            childIds = new List<int>();
                            children[parentId] = childIds;
                        }
                        childIds.Add(processId);
                        entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                    }
                    while (Process32NextW(snapshot, ref entry));
                }
            }
            finally
            {
                CloseHandle(snapshot);
            }

            var descendants = new List<int>();
            var queue = new Queue<int>();
            var seen = new HashSet<int>();
            queue.Enqueue(rootProcessId);
            seen.Add(rootProcessId);
            while (queue.Count > 0)
            {
                int parentId = queue.Dequeue();
                List<int> childIds;
                if (!children.TryGetValue(parentId, out childIds))
                {
                    continue;
                }
                foreach (int childId in childIds)
                {
                    if (!seen.Add(childId))
                    {
                        continue;
                    }
                    descendants.Add(childId);
                    queue.Enqueue(childId);
                }
            }
            return descendants.ToArray();
        }

        public static string ReadCommandLine(int processId)
        {
            IntPtr processHandle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (processHandle == IntPtr.Zero)
            {
                return null;
            }

            IntPtr buffer = IntPtr.Zero;
            try
            {
                int requiredLength;
                NtQueryInformationProcess(
                    processHandle,
                    PROCESS_COMMAND_LINE_INFORMATION,
                    IntPtr.Zero,
                    0,
                    out requiredLength);
                if (requiredLength <= 0)
                {
                    return null;
                }

                buffer = Marshal.AllocHGlobal(requiredLength);
                int returnedLength;
                int status = NtQueryInformationProcess(
                    processHandle,
                    PROCESS_COMMAND_LINE_INFORMATION,
                    buffer,
                    requiredLength,
                    out returnedLength);
                if (status != 0)
                {
                    return null;
                }

                UNICODE_STRING commandLine = (UNICODE_STRING)Marshal.PtrToStructure(
                    buffer,
                    typeof(UNICODE_STRING));
                if (commandLine.Buffer == IntPtr.Zero || commandLine.Length == 0)
                {
                    return null;
                }

                return Marshal.PtrToStringUni(commandLine.Buffer, commandLine.Length / 2);
            }
            finally
            {
                if (buffer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(buffer);
                }
                CloseHandle(processHandle);
            }
        }

        public static int ReadTcpListenerProcessId(int port)
        {
            int size = 0;
            uint result = GetExtendedTcpTable(
                IntPtr.Zero,
                ref size,
                false,
                AF_INET,
                TCP_TABLE_OWNER_PID_LISTENER,
                0);
            if (result != ERROR_INSUFFICIENT_BUFFER || size <= 0)
            {
                return 0;
            }

            for (int attempt = 0; attempt < 3; attempt++)
            {
                int allocatedSize = size;
                IntPtr buffer = Marshal.AllocHGlobal(allocatedSize);
                try
                {
                    result = GetExtendedTcpTable(
                        buffer,
                        ref size,
                        false,
                        AF_INET,
                        TCP_TABLE_OWNER_PID_LISTENER,
                        0);
                    if (result == ERROR_INSUFFICIENT_BUFFER) {
                        if (size <= allocatedSize) {
                            size = checked(allocatedSize * 2);
                        }
                        continue;
                    }
                    if (result != 0 || allocatedSize < sizeof(int))
                    {
                        return 0;
                    }

                    int rowCount = Marshal.ReadInt32(buffer);
                    int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                    long requiredSize = sizeof(int) + ((long)rowCount * rowSize);
                    if (rowCount < 0 || requiredSize > allocatedSize)
                    {
                        return 0;
                    }

                    IntPtr rowPointer = IntPtr.Add(buffer, sizeof(int));
                    for (int index = 0; index < rowCount; index++)
                    {
                        MIB_TCPROW_OWNER_PID row = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(
                            rowPointer,
                            typeof(MIB_TCPROW_OWNER_PID));
                        int localPort = (ushort)IPAddress.NetworkToHostOrder((short)row.LocalPort);
                        if (localPort == port)
                        {
                            return (int)row.OwningPid;
                        }

                        rowPointer = IntPtr.Add(rowPointer, rowSize);
                    }

                    return 0;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }

            return 0;
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Get-NativeProcessCommandLine {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    Initialize-ProjectProcessNativeMethods
    return [Project1.Windows.ProcessIntrospection]::ReadCommandLine($ProcessId)
}

function Get-NativeTcpListenerProcessId {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port)

    Initialize-ProjectProcessNativeMethods
    $processId = [Project1.Windows.ProcessIntrospection]::ReadTcpListenerProcessId($Port)
    if ($processId -le 0) {
        return $null
    }

    return $processId
}

function Get-ProjectProcessIdentity {
    param([Alias("Pid")][int]$ProcessId = $PID)

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $record = $null
    $executablePath = $null
    $commandLine = $null

    if ($ProcessId -eq $PID) {
        $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        try {
            $executablePath = $currentProcess.MainModule.FileName
        } finally {
            $currentProcess.Dispose()
        }

        $commandLine = [System.Environment]::CommandLine
    } else {
        $record = Get-ProcessRecord -ProcessId $ProcessId
        if ($null -ne $record) {
            $executablePath = Get-IdentityValue -Object $record -Names @("ExecutablePath")
            $commandLine = Get-IdentityValue -Object $record -Names @("CommandLine")
        }

        if ([string]::IsNullOrWhiteSpace([string]$commandLine)) {
            try {
                $commandLine = Get-NativeProcessCommandLine -ProcessId $ProcessId
            } catch {
                $commandLine = $null
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($executablePath)) {
        try {
            $executablePath = $process.Path
        } catch {
            try {
                $executablePath = $process.MainModule.FileName
            } catch {
                $executablePath = $null
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($executablePath)) {
        throw "Unable to determine executable path for process $ProcessId."
    }

    return [pscustomobject]@{
        Pid = $process.Id
        ExecutablePath = $executablePath
        StartTimeUtc = $process.StartTime.ToUniversalTime()
        CommandLine = $commandLine
    }
}

function Test-ProjectProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][psobject]$RecordedIdentity,
        [int]$ProcessId = $PID
    )

    $actualIdentity = Get-ProjectProcessIdentity -ProcessId $ProcessId

    $recordedPid = Get-IdentityValue -Object $RecordedIdentity -Names @("Pid", "PID", "ProcessId")
    if ($null -ne $recordedPid -and [int]$recordedPid -ne [int]$actualIdentity.Pid) {
        return $false
    }

    $recordedPath = Get-IdentityValue -Object $RecordedIdentity -Names @("ExecutablePath", "Path", "Executable")
    if (-not [string]::IsNullOrWhiteSpace($recordedPath)) {
        $normalizedRecordedPath = ConvertTo-NormalizedPath -Path $recordedPath
        $normalizedActualPath = ConvertTo-NormalizedPath -Path $actualIdentity.ExecutablePath
        if (-not $normalizedRecordedPath.Equals($normalizedActualPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    $recordedStartTime = Get-IdentityValue -Object $RecordedIdentity -Names @("StartTimeUtc", "StartTime", "StartedAtUtc")
    if ($null -ne $recordedStartTime) {
        $expectedStartTime = ConvertTo-UtcDateTime -Value $recordedStartTime
        if ($expectedStartTime -ne $actualIdentity.StartTimeUtc) {
            return $false
        }
    }

    $recordedCommandLine = Get-IdentityValue -Object $RecordedIdentity -Names @("CommandLine")
    if (-not [string]::IsNullOrWhiteSpace($recordedCommandLine)) {
        if (-not $recordedCommandLine.Equals($actualIdentity.CommandLine, [System.StringComparison]::Ordinal)) {
            return $false
        }
    }

    return $true
}

function Stop-CheckedCommandProcessTree {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    if ($Process.HasExited) {
        return
    }

    Initialize-ProjectProcessNativeMethods
    $descendantIds = @([Project1.Windows.ProcessIntrospection]::GetDescendantProcessIds($Process.Id))

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
    } catch {
    }

    for ($index = $descendantIds.Count - 1; $index -ge 0; $index--) {
        $child = Get-Process -Id $descendantIds[$index] -ErrorAction SilentlyContinue
        if ($null -eq $child) {
            continue
        }
        try {
            if (-not $child.HasExited) {
                $child.Kill()
                [void]$child.WaitForExit(5000)
            }
        } catch {
        } finally {
            $child.Dispose()
        }
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-ProjectRoot),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WindowsCommandArgument -Argument $_ }) -join " ")
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $jobHandle = [System.IntPtr]::Zero

    try {
        Initialize-ProjectProcessNativeMethods
        $jobHandle = [Project1.Windows.ProcessIntrospection]::CreateKillOnCloseJob()
        [void]$process.Start()
        if (($jobHandle -ne [System.IntPtr]::Zero) -and -not [Project1.Windows.ProcessIntrospection]::AssignToJob($jobHandle, $process.Handle)) {
            [Project1.Windows.ProcessIntrospection]::CloseJob($jobHandle)
            $jobHandle = [System.IntPtr]::Zero
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            if ($jobHandle -ne [System.IntPtr]::Zero) {
                [Project1.Windows.ProcessIntrospection]::CloseJob($jobHandle)
                $jobHandle = [System.IntPtr]::Zero
            } else {
                Stop-CheckedCommandProcessTree -Process $process
            }

            [void]$process.WaitForExit(5000)
            try {
                if (-not $stdoutTask.IsCompleted) {
                    [void]$stdoutTask.Wait(5000)
                }
                if (-not $stderrTask.IsCompleted) {
                    [void]$stderrTask.Wait(5000)
                }
            } catch {
            }

            throw "Process timed out after $TimeoutSeconds seconds: $FilePath $($startInfo.Arguments)"
        }

        $process.WaitForExit()
        if ($jobHandle -ne [System.IntPtr]::Zero) {
            [Project1.Windows.ProcessIntrospection]::CloseJob($jobHandle)
            $jobHandle = [System.IntPtr]::Zero
        }
        if (-not $stdoutTask.IsCompleted -and -not $stdoutTask.Wait(5000)) {
            throw "Process stdout did not close within 5 seconds: $FilePath $($startInfo.Arguments)"
        }
        if (-not $stderrTask.IsCompleted -and -not $stderrTask.Wait(5000)) {
            throw "Process stderr did not close within 5 seconds: $FilePath $($startInfo.Arguments)"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        if ($jobHandle -ne [System.IntPtr]::Zero) {
            [Project1.Windows.ProcessIntrospection]::CloseJob($jobHandle)
        }
        $process.Dispose()
    }

    $result = [pscustomobject]@{
        FilePath = $FilePath
        Arguments = $startInfo.Arguments
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }

    if ($exitCode -ne 0) {
        $message = "Process exited with code $exitCode`: $FilePath $($startInfo.Arguments)"
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $message += "`r`nSTDOUT:`r`n$stdout"
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $message += "`r`nSTDERR:`r`n$stderr"
        }

        throw $message
    }

    return $result
}

Export-ModuleMember -Function @(
    "Get-ProjectRoot",
    "Read-BootstrapManifest",
    "Compare-Version",
    "Test-VersionAtLeast",
    "Get-FileSha256",
    "Assert-FileHash",
    "Resolve-DeviceMode",
    "New-SecureToken",
    "New-LocalEnvContent",
    "Test-PathInsideRoot",
    "Get-NativeProcessCommandLine",
    "Get-NativeTcpListenerProcessId",
    "Get-ProjectProcessIdentity",
    "Test-ProjectProcessIdentity",
    "Invoke-CheckedCommand"
)
