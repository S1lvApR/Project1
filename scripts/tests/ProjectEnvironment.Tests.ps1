Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-False {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ($Expected -is [System.Array] -or $Actual -is [System.Array]) {
        if (-not [System.Linq.Enumerable]::SequenceEqual([object[]]$Expected, [object[]]$Actual)) {
            throw "$Message Expected: [$($Expected -join ', ')]. Actual: [$($Actual -join ', ')]."
        }

        return
    }

    if ($Expected -ne $Actual) {
        throw "$Message Expected: [$Expected]. Actual: [$Actual]."
    }
}

function Assert-Match {
    param(
        [string]$Pattern,
        [string]$Actual,
        [string]$Message
    )

    if ($Actual -notmatch $Pattern) {
        throw "$Message Pattern: [$Pattern]. Actual: [$Actual]."
    }
}

function Assert-Contains {
    param(
        [string]$ExpectedSubstring,
        [string]$Actual,
        [string]$Message
    )

    if ($null -eq $Actual -or $Actual.IndexOf($ExpectedSubstring, [System.StringComparison]::Ordinal) -lt 0) {
        throw "$Message Missing substring: [$ExpectedSubstring]."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage
    )

    try {
        & $Action
    } catch {
        if ($ExpectedMessage) {
            Assert-Contains -ExpectedSubstring $ExpectedMessage -Actual $_.Exception.Message -Message "Unexpected error message."
        }

        return $_.Exception.Message
    }

    throw "Expected an exception, but the action completed successfully."
}

function New-TempFixture {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Remove-TempFixture {
    param([string]$Path)

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force -Recurse
    }
}

function New-ValidBootstrapManifestObject {
    return @'
{
  "schemaVersion": 1,
  "runtime": {
    "python": {
      "version": "3.10.11",
      "filename": "python-3.10.11-amd64.exe",
      "url": "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
      "sha256": "D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B"
    },
    "node": {
      "version": "24.18.0",
      "filename": "node-v24.18.0-win-x64.zip",
      "url": "https://nodejs.org/dist/v24.18.0/node-v24.18.0-win-x64.zip",
      "sha256": "0AE68406B42D7725661DA979B1403EC9926DA205C6770827F33AAC9D8F26E821"
    }
  },
  "release": {
    "repository": "Dman-s/Project1",
    "tag": "models-v1",
    "models": [
      {
        "filename": "tt100k-yolo11s-reference42.pt",
        "bytes": 19231379,
        "sha256": "E8A0E0F1E5A9004C708D7EEE9EDD97E9E9D0A7986023E96C807D0FFCD3D50F88",
        "url": "https://github.com/Dman-s/Project1/releases/download/models-v1/tt100k-yolo11s-reference42.pt",
        "purpose": "default detector",
        "source": "user-provided 42-class reference training project",
        "license": "AGPL-3.0"
      },
      {
        "filename": "tt100k-yolo11n-common45.pt",
        "bytes": 5488602,
        "sha256": "A73829F11BD5AC940BDD1DF982095AE6F828180B0C3D55285BCDBB9333154D13",
        "url": "https://github.com/Dman-s/Project1/releases/download/models-v1/tt100k-yolo11n-common45.pt",
        "purpose": "optional detector",
        "source": "Project1 TT100K common-45 training",
        "license": "AGPL-3.0"
      },
      {
        "filename": "gtsrb-yolo11n-cls.pt",
        "bytes": 3291010,
        "sha256": "323E5BD1B0DC5D1F6FBB4C487FAF2320DA0DF9C21132DD46C0C94FEE7B33B16C",
        "url": "https://github.com/Dman-s/Project1/releases/download/models-v1/gtsrb-yolo11n-cls.pt",
        "purpose": "default classifier",
        "source": "Project1 GTSRB training",
        "license": "AGPL-3.0"
      }
    ]
  }
}
'@ | ConvertFrom-Json
}

function Assert-ManifestRejected {
    param(
        [scriptblock]$Mutation,
        [string]$ExpectedMessage
    )

    $fixture = New-TempFixture
    try {
        $path = Join-Path $fixture "manifest.json"
        $manifest = New-ValidBootstrapManifestObject
        & $Mutation $manifest
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding ASCII
        [void](Assert-Throws -Action { Read-BootstrapManifest -Path $path } -ExpectedMessage $ExpectedMessage)
    } finally {
        Remove-TempFixture -Path $fixture
    }
}

function Get-ReservedWindowsDeviceFilenames {
    $baseNames = @("CON", "PRN", "AUX", "NUL")
    $baseNames += 1..9 | ForEach-Object { "COM$_" }
    $baseNames += 1..9 | ForEach-Object { "LPT$_" }

    foreach ($baseName in $baseNames) {
        $lowerName = $baseName.ToLowerInvariant()
        $baseName
        $lowerName
        "$baseName.txt"
        "$lowerName.bin"
        "$baseName."
        "$lowerName "
        "$baseName.txt."
        "$lowerName.bin "
    }
}

function Get-ProjectEnvironmentTests {
    param(
        [string]$ModulePath,
        [string]$ManifestPath
    )

    return @(
        @{
            Name = "Get-ProjectRoot returns the worktree root"
            Body = {
                $expected = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ModulePath) "..\.."))
                $actual = Get-ProjectRoot
                Assert-Equal -Expected $expected -Actual $actual -Message "Project root mismatch."
            }
        },
        @{
            Name = "Windows PowerShell test scripts remain ASCII-compatible"
            Body = {
                $nonAsciiFiles = @(
                    Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.ps1" -File |
                        Where-Object {
                            @([System.IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0
                        } |
                        Select-Object -ExpandProperty Name
                )

                Assert-Equal -Expected @() -Actual $nonAsciiFiles -Message "Windows PowerShell 5.1 test scripts must parse under non-UTF-8 system code pages."
            }
        },
        @{
            Name = "Read-BootstrapManifest returns the expected runtime metadata"
            Body = {
                $manifest = Read-BootstrapManifest -Path $ManifestPath
                Assert-Equal -Expected 1 -Actual $manifest.schemaVersion -Message "schemaVersion mismatch."
                Assert-Equal -Expected "3.10.11" -Actual $manifest.runtime.python.version -Message "Python version mismatch."
                Assert-Equal -Expected "python-3.10.11-amd64.exe" -Actual $manifest.runtime.python.filename -Message "Python filename mismatch."
                Assert-Equal -Expected "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe" -Actual $manifest.runtime.python.url -Message "Python URL mismatch."
                Assert-Equal -Expected "D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B" -Actual $manifest.runtime.python.sha256 -Message "Python SHA mismatch."
                Assert-Equal -Expected "24.18.0" -Actual $manifest.runtime.node.version -Message "Node version mismatch."
                Assert-Equal -Expected "node-v24.18.0-win-x64.zip" -Actual $manifest.runtime.node.filename -Message "Node filename mismatch."
                Assert-Equal -Expected "https://nodejs.org/dist/v24.18.0/node-v24.18.0-win-x64.zip" -Actual $manifest.runtime.node.url -Message "Node URL mismatch."
                Assert-Equal -Expected "0AE68406B42D7725661DA979B1403EC9926DA205C6770827F33AAC9D8F26E821" -Actual $manifest.runtime.node.sha256 -Message "Node SHA mismatch."
                Assert-Equal -Expected "Dman-s/Project1" -Actual $manifest.release.repository -Message "Repository mismatch."
                Assert-Equal -Expected "models-v1" -Actual $manifest.release.tag -Message "Release tag mismatch."
                Assert-Equal -Expected 2 -Actual $manifest.release.models.Count -Message "Model count mismatch."

                $expectedModels = @(
                    [pscustomobject]@{
                        Filename = "tt100k-yolo11s-reference42.pt"
                        Bytes = 19231379
                        Sha256 = "E8A0E0F1E5A9004C708D7EEE9EDD97E9E9D0A7986023E96C807D0FFCD3D50F88"
                        Url = "https://github.com/Dman-s/Project1/releases/download/models-v1/tt100k-yolo11s-reference42.pt"
                        Purpose = "default detector"
                        Source = "42-class YOLO11 TT100K training project supplied by the repository owner"
                        License = "Ultralytics AGPL-3.0; TT100K CC-BY-NC"
                    },
                    [pscustomobject]@{
                        Filename = "gtsrb-yolo11n-cls.pt"
                        Bytes = 3291010
                        Sha256 = "323E5BD1B0DC5D1F6FBB4C487FAF2320DA0DF9C21132DD46C0C94FEE7B33B16C"
                        Url = "https://github.com/Dman-s/Project1/releases/download/models-v1/gtsrb-yolo11n-cls.pt"
                        Purpose = "default classifier"
                        Source = "Project1 GTSRB training"
                        License = "AGPL-3.0"
                    }
                )

                for ($index = 0; $index -lt $expectedModels.Count; $index++) {
                    $expected = $expectedModels[$index]
                    $actual = $manifest.release.models[$index]
                    Assert-Equal -Expected $expected.Filename -Actual $actual.filename -Message "Model filename mismatch."
                    Assert-Equal -Expected $expected.Bytes -Actual $actual.bytes -Message "Model bytes mismatch."
                    Assert-Equal -Expected $expected.Sha256 -Actual $actual.sha256 -Message "Model SHA mismatch."
                    Assert-Equal -Expected $expected.Url -Actual $actual.url -Message "Model URL mismatch."
                    Assert-Equal -Expected $expected.Purpose -Actual $actual.purpose -Message "Model purpose mismatch."
                    Assert-Equal -Expected $expected.Source -Actual $actual.source -Message "Model source mismatch."
                    Assert-Equal -Expected $expected.License -Actual $actual.license -Message "Model license mismatch."
                    Assert-True -Condition ($null -eq $actual.PSObject.Properties["size"]) -Message "Model must not contain size."
                    Assert-True -Condition ($null -eq $actual.PSObject.Properties["role"]) -Message "Model must not contain role."
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects an unsupported schemaVersion"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "manifest.json"
                    @'
{
  "schemaVersion": 2,
  "runtime": {
    "python": {
      "version": "3.10.11",
      "filename": "python-3.10.11-amd64.exe",
      "url": "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
      "sha256": "D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B"
    },
    "node": {
      "version": "24.18.0",
      "filename": "node-v24.18.0-win-x64.zip",
      "url": "https://nodejs.org/dist/v24.18.0/node-v24.18.0-win-x64.zip",
      "sha256": "0AE68406B42D7725661DA979B1403EC9926DA205C6770827F33AAC9D8F26E821"
    }
  },
  "release": {
    "repository": "Dman-s/Project1",
    "tag": "models-v1",
    "models": []
  }
}
'@ | Set-Content -LiteralPath $path -Encoding ASCII

                    [void](Assert-Throws -Action { Read-BootstrapManifest -Path $path } -ExpectedMessage "Unsupported bootstrap manifest schemaVersion")
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects missing required sections"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "manifest.json"
                    @'
{
  "schemaVersion": 1,
  "runtime": {
    "python": {
      "version": "3.10.11",
      "filename": "python-3.10.11-amd64.exe",
      "url": "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
      "sha256": "D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B"
    }
  },
  "release": {
    "repository": "Dman-s/Project1",
    "tag": "models-v1",
    "models": []
  }
}
'@ | Set-Content -LiteralPath $path -Encoding ASCII

                    [void](Assert-Throws -Action { Read-BootstrapManifest -Path $path } -ExpectedMessage "Missing required bootstrap manifest field")
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects a missing file"
            Body = {
                $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N") + ".json")
                [void](Assert-Throws -Action { Read-BootstrapManifest -Path $missingPath } -ExpectedMessage "")
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects malformed JSON"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "manifest.json"
                    "{not-json" | Set-Content -LiteralPath $path -Encoding ASCII
                    [void](Assert-Throws -Action { Read-BootstrapManifest -Path $path } -ExpectedMessage "")
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest requires model bytes purpose source and license"
            Body = {
                foreach ($field in @("bytes", "purpose", "source", "license")) {
                    $mutation = {
                        param($manifest)
                        $manifest.release.models[0].PSObject.Properties.Remove($field)
                    }.GetNewClosure()
                    Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "release.models[].$field"
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects empty model purpose source and license"
            Body = {
                foreach ($field in @("purpose", "source", "license")) {
                    $mutation = {
                        param($manifest)
                        $manifest.release.models[0].$field = " "
                    }.GetNewClosure()
                    Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "release.models[].$field"
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest requires numeric dotted runtime versions"
            Body = {
                foreach ($case in @(
                    [pscustomobject]@{ Runtime = "python"; Version = "3.10.x" },
                    [pscustomobject]@{ Runtime = "node"; Version = "24" }
                )) {
                    $mutation = {
                        param($manifest)
                        $manifest.runtime.($case.Runtime).version = $case.Version
                    }.GetNewClosure()
                    Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "runtime.$($case.Runtime).version"
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest requires HTTPS URLs"
            Body = {
                Assert-ManifestRejected -Mutation {
                    param($manifest)
                    $manifest.runtime.python.url = "http://www.python.org/python.exe"
                } -ExpectedMessage "runtime.python.url"
                Assert-ManifestRejected -Mutation {
                    param($manifest)
                    $manifest.release.models[0].url = "http://github.com/model.pt"
                } -ExpectedMessage "release.models[].url"
            }
        },
        @{
            Name = "Read-BootstrapManifest requires exact 64-character hexadecimal hashes"
            Body = {
                Assert-ManifestRejected -Mutation {
                    param($manifest)
                    $manifest.runtime.node.sha256 = "ABC123"
                } -ExpectedMessage "runtime.node.sha256"
                Assert-ManifestRejected -Mutation {
                    param($manifest)
                    $manifest.release.models[0].sha256 = ("G" * 64)
                } -ExpectedMessage "release.models[].sha256"
            }
        },
        @{
            Name = "Read-BootstrapManifest requires model bytes to be positive integers"
            Body = {
                foreach ($invalidBytes in @(0, -1, 1.5, "42")) {
                    $mutation = {
                        param($manifest)
                        $manifest.release.models[0].bytes = $invalidBytes
                    }.GetNewClosure()
                    Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "release.models[].bytes"
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects path-bearing runtime filenames"
            Body = {
                $invalidFilenames = @(
                    "../runtime.exe",
                    "..\runtime.exe",
                    "folder/runtime.exe",
                    "folder\runtime.exe",
                    "C:\runtime.exe",
                    "\\server\share\runtime.exe",
                    "\\?\C:\runtime.exe",
                    ".",
                    ".."
                )

                foreach ($runtimeName in @("python", "node")) {
                    foreach ($invalidFilename in $invalidFilenames) {
                        $mutation = {
                            param($manifest)
                            $manifest.runtime.($runtimeName).filename = $invalidFilename
                        }.GetNewClosure()
                        Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "runtime.$runtimeName.filename"
                    }
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects path-bearing model filenames"
            Body = {
                $invalidFilenames = @(
                    "../model.pt",
                    "..\model.pt",
                    "folder/model.pt",
                    "folder\model.pt",
                    "C:\model.pt",
                    "\\server\share\model.pt",
                    "\\?\C:\model.pt",
                    ".",
                    ".."
                )

                foreach ($invalidFilename in $invalidFilenames) {
                    $mutation = {
                        param($manifest)
                        $manifest.release.models[0].filename = $invalidFilename
                    }.GetNewClosure()
                    Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "release.models[].filename"
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects reserved Windows runtime filenames"
            Body = {
                foreach ($runtimeName in @("python", "node")) {
                    foreach ($invalidFilename in (Get-ReservedWindowsDeviceFilenames)) {
                        $mutation = {
                            param($manifest)
                            $manifest.runtime.($runtimeName).filename = $invalidFilename
                        }.GetNewClosure()
                        Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "runtime.$runtimeName.filename"
                    }
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest rejects reserved Windows model filenames before URL validation"
            Body = {
                foreach ($invalidFilename in (Get-ReservedWindowsDeviceFilenames)) {
                    $mutation = {
                        param($manifest)
                        $model = $manifest.release.models[0]
                        $model.filename = $invalidFilename
                        $model.url = "https://github.com/$($manifest.release.repository)/releases/download/$($manifest.release.tag)/$invalidFilename"
                    }.GetNewClosure()
                    Assert-ManifestRejected -Mutation $mutation -ExpectedMessage "release.models[].filename"
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest accepts dotted and hyphenated leaf filenames"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "manifest.json"
                    $manifest = New-ValidBootstrapManifestObject
                    $manifest.runtime.python.filename = "python.runtime-3.10.11.exe"
                    $manifest.release.models[0].filename = "model.weights-v1.pt"
                    $manifest.release.models[0].url = "https://github.com/Dman-s/Project1/releases/download/models-v1/model.weights-v1.pt"
                    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding ASCII

                    $actual = Read-BootstrapManifest -Path $path
                    Assert-Equal -Expected "python.runtime-3.10.11.exe" -Actual $actual.runtime.python.filename -Message "Runtime leaf filename mismatch."
                    Assert-Equal -Expected "model.weights-v1.pt" -Actual $actual.release.models[0].filename -Message "Model leaf filename mismatch."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Read-BootstrapManifest requires model URLs to match release repository tag and filename"
            Body = {
                Assert-ManifestRejected -Mutation {
                    param($manifest)
                    $manifest.release.models[0].url = "https://github.com/Other/Repository/releases/download/models-v1/tt100k-yolo11s-reference42.pt"
                } -ExpectedMessage "release.models[].url"
                Assert-ManifestRejected -Mutation {
                    param($manifest)
                    $manifest.release.models[0].url = "https://github.com/Dman-s/Project1/releases/download/models-v1/wrong-name.pt"
                } -ExpectedMessage "release.models[].url"
            }
        },
        @{
            Name = "Read-BootstrapManifest derives model URL prefix from release metadata"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "manifest.json"
                    $manifest = New-ValidBootstrapManifestObject
                    $manifest.release.repository = "Example/Bootstrap"
                    $manifest.release.tag = "weights-v2"
                    foreach ($model in $manifest.release.models) {
                        $model.url = "https://github.com/Example/Bootstrap/releases/download/weights-v2/$($model.filename)"
                    }
                    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding ASCII

                    $actual = Read-BootstrapManifest -Path $path
                    Assert-Equal -Expected "Example/Bootstrap" -Actual $actual.release.repository -Message "Repository should not be hard-coded."
                    Assert-Equal -Expected "weights-v2" -Actual $actual.release.tag -Message "Tag should not be hard-coded."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Compare-Version treats trailing zero segments as equal"
            Body = {
                Assert-Equal -Expected 0 -Actual (Compare-Version -LeftVersion "3.10.11" -RightVersion "3.10.11.0") -Message "Version equality comparison failed."
            }
        },
        @{
            Name = "Compare-Version compares numeric segments"
            Body = {
                Assert-Equal -Expected 1 -Actual (Compare-Version -LeftVersion "24.18.0" -RightVersion "24.3.9") -Message "Numeric version comparison failed."
                Assert-Equal -Expected -1 -Actual (Compare-Version -LeftVersion "3.9.99" -RightVersion "3.10.0") -Message "Lower version comparison failed."
            }
        },
        @{
            Name = "Compare-Version rejects invalid dotted versions"
            Body = {
                [void](Assert-Throws -Action { Compare-Version -LeftVersion "1.two.3" -RightVersion "1.2.3" } -ExpectedMessage "Invalid version segment")
            }
        },
        @{
            Name = "Test-VersionAtLeast returns true for matching or newer versions"
            Body = {
                Assert-True -Condition (Test-VersionAtLeast -ActualVersion "24.18.0" -MinimumVersion "24.18") -Message "Expected version to satisfy the minimum."
            }
        },
        @{
            Name = "Test-VersionAtLeast returns false for older versions"
            Body = {
                Assert-False -Condition (Test-VersionAtLeast -ActualVersion "3.10.10" -MinimumVersion "3.10.11") -Message "Expected version to be rejected."
            }
        },
        @{
            Name = "Test-VersionAtLeast rejects malformed versions"
            Body = {
                [void](Assert-Throws -Action { Test-VersionAtLeast -ActualVersion "3.x" -MinimumVersion "3.10" } -ExpectedMessage "Invalid version segment")
            }
        },
        @{
            Name = "Get-FileSha256 returns the file digest"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "payload.txt"
                    [System.IO.File]::WriteAllText($path, "abc", [System.Text.Encoding]::ASCII)
                    $sha = Get-FileSha256 -Path $path
                    Assert-Equal -Expected "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD" -Actual $sha -Message "SHA256 mismatch."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Assert-FileHash accepts case-insensitive expected digests"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "payload.txt"
                    [System.IO.File]::WriteAllText($path, "abc", [System.Text.Encoding]::ASCII)
                    Assert-FileHash -Path $path -ExpectedSha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Get-FileSha256 reports one clean contextual error for a missing file"
            Body = {
                $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
                $records = @(& {
                    try {
                        Get-FileSha256 -Path $missingPath
                    } catch {
                        [pscustomobject]@{ Message = $_.Exception.Message }
                    }
                } 2>&1)

                Assert-Equal -Expected 1 -Actual $records.Count -Message "Missing-file hash failure leaked output or errors."
                Assert-Contains -ExpectedSubstring "Unable to calculate SHA256 for '$missingPath'" -Actual $records[0].Message -Message "Missing-file hash error lacked context."
            }
        },
        @{
            Name = "Assert-FileHash throws with expected and actual digests"
            Body = {
                $fixture = New-TempFixture
                try {
                    $path = Join-Path $fixture "payload.txt"
                    [System.IO.File]::WriteAllText($path, "abc", [System.Text.Encoding]::ASCII)
                    $message = Assert-Throws -Action { Assert-FileHash -Path $path -ExpectedSha256 "DEADBEEF" } -ExpectedMessage "File SHA256 mismatch"
                    Assert-Contains -ExpectedSubstring "Expected: DEADBEEF" -Actual $message -Message "Expected digest not reported."
                    Assert-Contains -ExpectedSubstring "Actual: BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD" -Actual $message -Message "Actual digest not reported."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Resolve-DeviceMode preserves cpu"
            Body = {
                Assert-Equal -Expected "cpu" -Actual (Resolve-DeviceMode -RequestedMode "cpu" -HasNvidia $true) -Message "CPU mode mismatch."
            }
        },
        @{
            Name = "Assert-FileHash rejects a missing file"
            Body = {
                $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
                [void](Assert-Throws -Action { Assert-FileHash -Path $missingPath -ExpectedSha256 ("0" * 64) } -ExpectedMessage "")
            }
        },
        @{
            Name = "Resolve-DeviceMode maps auto based on Nvidia availability"
            Body = {
                Assert-Equal -Expected "gpu" -Actual (Resolve-DeviceMode -RequestedMode "auto" -HasNvidia $true) -Message "Auto GPU resolution mismatch."
                Assert-Equal -Expected "cpu" -Actual (Resolve-DeviceMode -RequestedMode "auto" -HasNvidia $false) -Message "Auto CPU resolution mismatch."
            }
        },
        @{
            Name = "Resolve-DeviceMode rejects gpu when Nvidia is unavailable"
            Body = {
                [void](Assert-Throws -Action { Resolve-DeviceMode -RequestedMode "gpu" -HasNvidia $false } -ExpectedMessage "GPU mode requires Nvidia support")
            }
        },
        @{
            Name = "New-SecureToken returns a default 64-character hexadecimal token"
            Body = {
                $token = New-SecureToken
                Assert-Equal -Expected 64 -Actual $token.Length -Message "Default token length mismatch."
                Assert-Match -Pattern "^[0-9A-F]+$" -Actual $token -Message "Token format mismatch."
            }
        },
        @{
            Name = "New-SecureToken honors the byte count"
            Body = {
                $token = New-SecureToken -ByteCount 16
                Assert-Equal -Expected 32 -Actual $token.Length -Message "Custom token length mismatch."
            }
        },
        @{
            Name = "New-SecureToken rejects an invalid byte count"
            Body = {
                [void](Assert-Throws -Action { New-SecureToken -ByteCount 0 } -ExpectedMessage "")
            }
        },
        @{
            Name = "New-LocalEnvContent is deterministic apart from the supplied secret"
            Body = {
                $previous = $env:UNRELATED_SECRET_TOKEN
                $env:UNRELATED_SECRET_TOKEN = "should-not-leak"
                try {
                    $content = New-LocalEnvContent -JwtSecretKey "local-secret-value" -YoloDevice "gpu" -GtsrbDevice "cpu"
                    $resolvedModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
                    $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedModulePath))
                    $publicTemplatePath = Join-Path $projectRoot "backend\.env.local.example"
                    $expectedLines = @([System.IO.File]::ReadAllLines($publicTemplatePath, [System.Text.Encoding]::UTF8) | ForEach-Object {
                        $line = $_.Trim()
                        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { return }
                        if ($line.StartsWith("YOLO_DEVICE=")) { return "YOLO_DEVICE=gpu" }
                        if ($line.StartsWith("GTSRB_DEVICE=")) { return "GTSRB_DEVICE=cpu" }
                        if ($line.StartsWith("JWT_SECRET_KEY=")) { return "JWT_SECRET_KEY=local-secret-value" }
                        return $line
                    })
                    $expected = $expectedLines -join "`r`n"
                    Assert-Equal -Expected ($expected + "`r`n") -Actual $content -Message "Local env content mismatch."
                    Assert-Contains -ExpectedSubstring "YOLO_USE_SAHI=true" -Actual $content -Message "Public template must keep SAHI enabled for the default detector."
                    Assert-Contains -ExpectedSubstring "YOLO_MODEL_NAME=tt100k-yolo11s-reference42" -Actual $content -Message "Public template must identify the requested 42-class detector."
                    Assert-Contains -ExpectedSubstring "YOLO_IMAGE_SIZE=1280" -Actual $content -Message "Video inference must preserve small traffic signs by default."
                    Assert-Contains -ExpectedSubstring "VIDEO_FRAME_SAMPLE_RATE=1" -Actual $content -Message "Video inference must cover every frame by default."
                    Assert-Contains -ExpectedSubstring "VIDEO_MAX_FRAMES=0" -Actual $content -Message "Video inference must not truncate the timeline by default."
                    Assert-Contains -ExpectedSubstring "VIDEO_SPEED_REFINEMENT_PL40_MIN_CONFIDENCE=0.75" -Actual $content -Message "The calibrated pl40-to-pl50 review threshold must be generated."
                    Assert-False -Condition ($content.Contains("should-not-leak")) -Message "Unexpected environment leak."

                    $templatePath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N") + ".env.example")
                    try {
                        [System.IO.File]::WriteAllLines($templatePath, @(
                            "# fixture",
                            "YOLO_DEVICE=auto",
                            "GTSRB_DEVICE=auto",
                            "YOLO_CONFIDENCE=0.61",
                            "JWT_SECRET_KEY=generated-by-bootstrap"
                        ), (New-Object System.Text.UTF8Encoding($false)))
                        $fromTemplate = New-LocalEnvContent -JwtSecretKey "fixture-secret" -YoloDevice "gpu" -GtsrbDevice "cpu" -TemplatePath $templatePath
                        Assert-Contains -ExpectedSubstring "YOLO_CONFIDENCE=0.61" -Actual $fromTemplate -Message "Generated env should preserve template-owned settings."
                        Assert-Contains -ExpectedSubstring "YOLO_DEVICE=gpu" -Actual $fromTemplate -Message "Generated env should replace the YOLO device."
                        Assert-Contains -ExpectedSubstring "GTSRB_DEVICE=cpu" -Actual $fromTemplate -Message "Generated env should replace the GTSRB device."
                        Assert-Contains -ExpectedSubstring "JWT_SECRET_KEY=fixture-secret" -Actual $fromTemplate -Message "Generated env should replace the JWT marker."
                        Assert-False -Condition $fromTemplate.Contains("generated-by-bootstrap") -Message "Generated env must not retain the JWT marker."
                    } finally {
                        Remove-Item -LiteralPath $templatePath -Force -ErrorAction SilentlyContinue
                    }
                } finally {
                    $env:UNRELATED_SECRET_TOKEN = $previous
                }
            }
        },
        @{
            Name = "Dependency guide stays aligned with repository manifests"
            Body = {
                $manifest = Read-BootstrapManifest -Path $ManifestPath
                $resolvedModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
                $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedModulePath))
                $guidePath = Join-Path $projectRoot "docs\dependencies.md"
                Assert-True -Condition (Test-Path -LiteralPath $guidePath -PathType Leaf) -Message "Dependency guide is missing."
                $content = [System.IO.File]::ReadAllText($guidePath, [System.Text.Encoding]::UTF8)

                Assert-Contains -ExpectedSubstring ([string]$manifest.runtime.python.version) -Actual $content -Message "Python runtime version is missing from the dependency guide."
                Assert-Contains -ExpectedSubstring ([string]$manifest.runtime.node.version) -Actual $content -Message "Node runtime version is missing from the dependency guide."
                foreach ($model in @($manifest.release.models)) {
                    Assert-Contains -ExpectedSubstring ([string]$model.filename) -Actual $content -Message "Model filename is missing from the dependency guide."
                    Assert-Contains -ExpectedSubstring ([string]$model.bytes) -Actual $content -Message "Model size is missing from the dependency guide."
                    Assert-Contains -ExpectedSubstring ([string]$model.sha256) -Actual $content -Message "Model hash is missing from the dependency guide."
                }

                foreach ($requiredText in @(
                    "requirements-cpu.txt",
                    "requirements-gpu.txt",
                    "requirements-common.lock",
                    "package-lock.json",
                    "torch==2.11.0+cpu",
                    "torch==2.11.0+cu128",
                    "CUDA 12.8",
                    "SQLite",
                    "PostgreSQL",
                    "Redis",
                    "MinIO",
                    "system FFmpeg",
                    "CUDA Toolkit",
                    "WSL",
                    "Docker"
                )) {
                    Assert-Contains -ExpectedSubstring $requiredText -Actual $content -Message ("Dependency guide is missing: " + $requiredText)
                }
            }
        },
        @{
            Name = "Repository manifest publishes only the requested 42-class detector"
            Body = {
                $manifest = Read-BootstrapManifest -Path $ManifestPath
                $filenames = @($manifest.release.models | ForEach-Object { [string]$_.filename })
                Assert-True -Condition ($filenames -contains "tt100k-yolo11s-reference42.pt") -Message "The release manifest must include the requested 42-class detector."
                Assert-False -Condition ($filenames -contains "tt100k-yolo11n-common45.pt") -Message "The project-trained common-45 detector must not be published."
                $defaultDetector = @($manifest.release.models | Where-Object { $_.purpose -eq "default detector" })
                Assert-Equal -Expected 1 -Actual $defaultDetector.Count -Message "The release manifest must identify one default detector."
                Assert-Equal -Expected "tt100k-yolo11s-reference42.pt" -Actual $defaultDetector[0].filename -Message "The 42-class detector should be the release default."
                Assert-Contains -ExpectedSubstring "TT100K CC-BY-NC" -Actual ([string]$defaultDetector[0].license) -Message "TT100K-derived weights must carry the dataset restriction in metadata."
            }
        },
        @{
            Name = "Test-PathInsideRoot accepts descendants"
            Body = {
                Assert-True -Condition (Test-PathInsideRoot -RootPath "C:\repo" -Path "C:\repo\scripts\bootstrap.ps1") -Message "Expected descendant path to be accepted."
            }
        },
        @{
            Name = "New-LocalEnvContent rejects empty secrets and invalid devices"
            Body = {
                [void](Assert-Throws -Action { New-LocalEnvContent -JwtSecretKey " " -YoloDevice "cpu" -GtsrbDevice "cpu" } -ExpectedMessage "JwtSecretKey")
                [void](Assert-Throws -Action { New-LocalEnvContent -JwtSecretKey "secret" -YoloDevice "" -GtsrbDevice "cpu" } -ExpectedMessage "")
            }
        },
        @{
            Name = "Test-PathInsideRoot accepts the root itself"
            Body = {
                Assert-True -Condition (Test-PathInsideRoot -RootPath "C:\repo" -Path "C:\repo\") -Message "Root path should be accepted."
            }
        },
        @{
            Name = "Test-PathInsideRoot rejects sibling-prefix tricks"
            Body = {
                Assert-False -Condition (Test-PathInsideRoot -RootPath "C:\repo" -Path "C:\repo-backup\file.txt") -Message "Sibling prefix path should be rejected."
            }
        },
        @{
            Name = "Test-PathInsideRoot rejects escaping through dot segments"
            Body = {
                Assert-False -Condition (Test-PathInsideRoot -RootPath "C:\repo" -Path "C:\repo\subdir\..\..\Windows\System32") -Message "Escaped path should be rejected."
            }
        },
        @{
            Name = "Get-ProjectProcessIdentity returns current process metadata"
            Body = {
                $identity = Get-ProjectProcessIdentity
                Assert-Equal -Expected $PID -Actual $identity.Pid -Message "Process id mismatch."
                Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($identity.ExecutablePath)) -Message "Executable path should not be empty."
                Assert-True -Condition ($identity.StartTimeUtc.Kind -eq [System.DateTimeKind]::Utc) -Message "Start time should be UTC."
                Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($identity.CommandLine)) -Message "Command line should not be empty."
            }
        },
        @{
            Name = "Test-ProjectProcessIdentity matches the current process"
            Body = {
                $identity = Get-ProjectProcessIdentity
                Assert-True -Condition (Test-ProjectProcessIdentity -RecordedIdentity $identity) -Message "Identity comparison should succeed."
            }
        },
        @{
            Name = "Get-ProjectProcessIdentity rejects a nonexistent process"
            Body = {
                [void](Assert-Throws -Action { Get-ProjectProcessIdentity -ProcessId ([int]::MaxValue) } -ExpectedMessage "")
            }
        },
        @{
            Name = "Get-ProjectProcessIdentity accepts both ProcessId and Pid for a harmless child process"
            Body = {
                $fixture = New-TempFixture
                $process = $null
                try {
                    $scriptPath = Join-Path $fixture "identity-child.ps1"
                    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
while ($true) {
    Start-Sleep -Milliseconds 250
}
'@ | Set-Content -LiteralPath $scriptPath -Encoding ASCII

                    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $startInfo.FileName = (Join-Path $PSHOME "powershell.exe")
                    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true

                    $process = New-Object System.Diagnostics.Process
                    $process.StartInfo = $startInfo
                    [void]$process.Start()

                    Start-Sleep -Seconds 1

                    $byProcessId = Get-ProjectProcessIdentity -ProcessId $process.Id
                    $byPid = Get-ProjectProcessIdentity -Pid $process.Id

                    Assert-Equal -Expected $process.Id -Actual $byProcessId.Pid -Message "ProcessId lookup should return the child pid."
                    Assert-Equal -Expected $process.Id -Actual $byPid.Pid -Message "Pid alias lookup should return the child pid."
                    Assert-Equal -Expected $byProcessId.Pid -Actual $byPid.Pid -Message "ProcessId and Pid should resolve the same child process."
                } finally {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) {
                                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            }
                        } catch {
                        } finally {
                            $process.Dispose()
                        }
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Get-NativeProcessCommandLine reads a harmless child process command line"
            Body = {
                $fixture = New-TempFixture
                $process = $null
                try {
                    $scriptPath = Join-Path $fixture "native-command-line-child.ps1"
                    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
while ($true) {
    Start-Sleep -Milliseconds 250
}
'@ | Set-Content -LiteralPath $scriptPath -Encoding ASCII

                    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $startInfo.FileName = (Join-Path $PSHOME "powershell.exe")
                    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true

                    $process = New-Object System.Diagnostics.Process
                    $process.StartInfo = $startInfo
                    [void]$process.Start()
                    Start-Sleep -Milliseconds 500

                    $commandLine = Get-NativeProcessCommandLine -ProcessId $process.Id
                    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$commandLine)) -Message "Native process command line should not be empty."
                    Assert-Contains -ExpectedSubstring $scriptPath -Actual ([string]$commandLine) -Message "Native process command line should contain the launched script path."
                } finally {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) {
                                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            }
                        } catch {
                        } finally {
                            $process.Dispose()
                        }
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Get-NativeTcpListenerProcessId resolves the current listener owner"
            Body = {
                $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
                try {
                    $listener.Start()
                    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
                    $ownerPid = Get-NativeTcpListenerProcessId -Port $port
                    Assert-Equal -Expected $PID -Actual $ownerPid -Message "Native TCP listener lookup should return the owning process id."
                } finally {
                    $listener.Stop()
                }
            }
        },
        @{
            Name = "Test-ProjectProcessIdentity rejects a command line mismatch when the actual command line is available"
            Body = {
                $identity = Get-ProjectProcessIdentity
                $mutated = [pscustomobject]@{
                    Pid = $identity.Pid
                    ExecutablePath = $identity.ExecutablePath
                    StartTimeUtc = $identity.StartTimeUtc
                    CommandLine = ([string]$identity.CommandLine) + " --mismatch"
                }

                Assert-False -Condition (Test-ProjectProcessIdentity -RecordedIdentity $mutated) -Message "Identity comparison should fail when the actual command line is available and mismatched."
            }
        },
        @{
            Name = "Get-ProjectProcessIdentity supplies a child command line for exact matching"
            Body = {
                $fixture = New-TempFixture
                $process = $null
                try {
                    $scriptPath = Join-Path $fixture "identity-child.ps1"
                    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
while ($true) {
    Start-Sleep -Milliseconds 250
}
'@ | Set-Content -LiteralPath $scriptPath -Encoding ASCII

                    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $startInfo.FileName = (Join-Path $PSHOME "powershell.exe")
                    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true

                    $process = New-Object System.Diagnostics.Process
                    $process.StartInfo = $startInfo
                    [void]$process.Start()
                    Start-Sleep -Seconds 1

                    $identity = Get-ProjectProcessIdentity -ProcessId $process.Id
                    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$identity.CommandLine)) -Message "Child command line should be available even when management APIs are unavailable."

                    $recorded = [pscustomobject]@{
                        Pid = $identity.Pid
                        ExecutablePath = $identity.ExecutablePath
                        StartTimeUtc = $identity.StartTimeUtc.ToString("o")
                        CommandLine = $identity.CommandLine
                    }

                    Assert-True -Condition (Test-ProjectProcessIdentity -RecordedIdentity $recorded -ProcessId $process.Id) -Message "Identity comparison should accept the exact child command line."
                    $recorded.CommandLine = ([string]$recorded.CommandLine) + " --mismatch"
                    Assert-False -Condition (Test-ProjectProcessIdentity -RecordedIdentity $recorded -ProcessId $process.Id) -Message "Identity comparison should still reject a child command line mismatch."
                } finally {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) {
                                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            }
                        } catch {
                        } finally {
                            $process.Dispose()
                        }
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Test-ProjectProcessIdentity rejects mismatched identities"
            Body = {
                $identity = Get-ProjectProcessIdentity
                $mutated = [pscustomobject]@{
                    Pid = $identity.Pid + 1
                    ExecutablePath = $identity.ExecutablePath
                    StartTimeUtc = $identity.StartTimeUtc
                    CommandLine = $identity.CommandLine
                }
                Assert-False -Condition (Test-ProjectProcessIdentity -RecordedIdentity $mutated) -Message "Identity comparison should fail."
            }
        },
        @{
            Name = "Invoke-CheckedCommand captures stdout and stderr"
            Body = {
                $filePath = Join-Path $PSHOME "powershell.exe"
                $result = Invoke-CheckedCommand -FilePath $filePath -ArgumentList @(
                    "-NoProfile",
                    "-Command",
                    "[Console]::Out.WriteLine('alpha beta'); [Console]::Error.WriteLine('warn line')"
                )

                Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "Exit code mismatch."
                Assert-Contains -ExpectedSubstring "alpha beta" -Actual $result.StdOut -Message "stdout mismatch."
                Assert-Contains -ExpectedSubstring "warn line" -Actual $result.StdErr -Message "stderr mismatch."
            }
        },
        @{
            Name = "Invoke-CheckedCommand drains high-volume stdout and stderr without deadlock"
            Body = {
                $fixture = New-TempFixture
                $process = $null
                try {
                    $scriptPath = Join-Path $fixture "invoke-high-volume.ps1"
                    $escapedModulePath = $ModulePath.Replace("'", "''")
                    $childScript = @"
`$ErrorActionPreference = "Stop"
Import-Module '$escapedModulePath' -Force
`$filePath = Join-Path `$PSHOME "powershell.exe"
`$command = '`$stdoutChunk = "O" * 4096; `$stderrChunk = "E" * 4096; for (`$index = 0; `$index -lt 512; `$index++) { [Console]::Out.WriteLine(`$stdoutChunk); [Console]::Error.WriteLine(`$stderrChunk) }'
`$result = Invoke-CheckedCommand -FilePath `$filePath -ArgumentList @("-NoProfile", "-Command", `$command)
if (`$result.StdOut.Length -lt 2097152 -or `$result.StdErr.Length -lt 2097152) {
    throw "High-volume output was not fully captured."
}
Write-Output "completed"
"@
                    $childScript | Set-Content -LiteralPath $scriptPath -Encoding ASCII

                    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
                    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $startInfo.UseShellExecute = $false
                    $startInfo.RedirectStandardOutput = $true
                    $startInfo.RedirectStandardError = $true
                    $startInfo.CreateNoWindow = $true

                    $process = New-Object System.Diagnostics.Process
                    $process.StartInfo = $startInfo
                    [void]$process.Start()

                    if (-not $process.WaitForExit(10000)) {
                        $process.Kill()
                        [void]$process.WaitForExit(5000)
                        throw "Invoke-CheckedCommand timed out while draining high-volume stdout and stderr."
                    }

                    $stdout = $process.StandardOutput.ReadToEnd()
                    $stderr = $process.StandardError.ReadToEnd()
                    Assert-Equal -Expected 0 -Actual $process.ExitCode -Message "Bounded child process failed. stdout: $stdout stderr: $stderr"
                    Assert-Contains -ExpectedSubstring "completed" -Actual $stdout -Message "Bounded child did not complete."
                } finally {
                    if ($null -ne $process) {
                        if (-not $process.HasExited) {
                            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                        }
                        $process.Dispose()
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-CheckedCommand times out and terminates the child process without leaking it"
            Body = {
                $fixture = New-TempFixture
                try {
                    $scriptPath = Join-Path $fixture "block.ps1"
                    $pidPath = Join-Path $fixture "child.pid"
                    @"
Set-Content -LiteralPath '$($pidPath.Replace("'", "''"))' -Value `$PID -Encoding ASCII
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $scriptPath -Encoding ASCII

                    $filePath = Join-Path $PSHOME "powershell.exe"
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $message = Assert-Throws -Action {
                        Invoke-CheckedCommand -FilePath $filePath -ArgumentList @(
                            "-NoProfile",
                            "-ExecutionPolicy",
                            "Bypass",
                            "-File",
                            $scriptPath
                        ) -TimeoutSeconds 2
                    } -ExpectedMessage "timed out"
                    $stopwatch.Stop()

                    Assert-True -Condition ($stopwatch.Elapsed.TotalSeconds -lt 10) -Message "Timed-out command did not return in bounded time."
                    Assert-False -Condition ($message.Contains("STDOUT:")) -Message "Timeout failures must not include child stdout."
                    Assert-False -Condition ($message.Contains("STDERR:")) -Message "Timeout failures must not include child stderr."
                    Assert-True -Condition (Test-Path -LiteralPath $pidPath -PathType Leaf) -Message "Timed-out child did not write its pid file."

                    $childPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
                    Start-Sleep -Milliseconds 200
                    Assert-True -Condition ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) -Message "Timed-out child process was not terminated."
                } finally {
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-CheckedCommand timeout terminates the complete child process tree"
            Body = {
                $fixture = New-TempFixture
                $grandchildPid = $null
                try {
                    $grandchildScript = Join-Path $fixture "grandchild.ps1"
                    $parentScript = Join-Path $fixture "parent.ps1"
                    $grandchildPidPath = Join-Path $fixture "grandchild.pid"
                    @"
Set-Content -LiteralPath '$($grandchildPidPath.Replace("'", "''"))' -Value `$PID -Encoding ASCII
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $grandchildScript -Encoding ASCII
                    @"
`$powershellPath = Join-Path `$PSHOME 'powershell.exe'
`$null = Start-Process -FilePath `$powershellPath -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '$($grandchildScript.Replace("'", "''"))') -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $parentScript -Encoding ASCII

                    $filePath = Join-Path $PSHOME "powershell.exe"
                    [void](Assert-Throws -Action {
                        Invoke-CheckedCommand -FilePath $filePath -ArgumentList @(
                            "-NoProfile",
                            "-ExecutionPolicy",
                            "Bypass",
                            "-File",
                            $parentScript
                        ) -TimeoutSeconds 3
                    } -ExpectedMessage "timed out")

                    Assert-True -Condition (Test-Path -LiteralPath $grandchildPidPath -PathType Leaf) -Message "Grandchild did not publish its PID before timeout."
                    $grandchildPid = [int](Get-Content -LiteralPath $grandchildPidPath -Raw).Trim()
                    Start-Sleep -Milliseconds 300
                    Assert-True -Condition ($null -eq (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue)) -Message "Timed-out command left a grandchild process running."
                } finally {
                    if ($null -ne $grandchildPid) {
                        Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-CheckedCommand cleans up descendants after the parent exits"
            Body = {
                $fixture = New-TempFixture
                $grandchildPid = $null
                try {
                    $grandchildScript = Join-Path $fixture "detached-grandchild.ps1"
                    $parentScript = Join-Path $fixture "short-parent.ps1"
                    $grandchildPidPath = Join-Path $fixture "detached-grandchild.pid"
                    "Start-Sleep -Seconds 30" | Set-Content -LiteralPath $grandchildScript -Encoding ASCII
                    @"
`$startInfo = New-Object System.Diagnostics.ProcessStartInfo
`$startInfo.FileName = Join-Path `$PSHOME 'powershell.exe'
`$startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "$($grandchildScript.Replace("'", "''"))"'
`$startInfo.UseShellExecute = `$true
`$startInfo.CreateNoWindow = `$true
`$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
`$child = New-Object System.Diagnostics.Process
`$child.StartInfo = `$startInfo
[void]`$child.Start()
[System.IO.File]::WriteAllText('$($grandchildPidPath.Replace("'", "''"))', [string](`$child.Id), [System.Text.Encoding]::ASCII)
`$child.Dispose()
"@ | Set-Content -LiteralPath $parentScript -Encoding ASCII

                    $filePath = Join-Path $PSHOME "powershell.exe"
                    $result = Invoke-CheckedCommand -FilePath $filePath -ArgumentList @(
                        "-NoProfile",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-File",
                        $parentScript
                    ) -TimeoutSeconds 10

                    Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "Short parent process should exit successfully."
                    $grandchildPidText = $null
                    for ($attempt = 0; $attempt -lt 20; $attempt++) {
                        if (Test-Path -LiteralPath $grandchildPidPath -PathType Leaf) {
                            $grandchildPidText = (Get-Content -LiteralPath $grandchildPidPath -Raw -ErrorAction SilentlyContinue)
                            if (-not [string]::IsNullOrWhiteSpace($grandchildPidText)) {
                                break
                            }
                        }
                        Start-Sleep -Milliseconds 100
                    }
                    Assert-False -Condition ([string]::IsNullOrWhiteSpace($grandchildPidText)) -Message "Short parent did not publish its child PID."
                    $grandchildPid = [int]$grandchildPidText.Trim()
                    Start-Sleep -Milliseconds 300
                    Assert-True -Condition ($null -eq (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue)) -Message "Checked command left a descendant running after its parent exited."
                } finally {
                    if ($null -ne $grandchildPid) {
                        Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue
                    }
                    Remove-TempFixture -Path $fixture
                }
            }
        },
        @{
            Name = "Invoke-CheckedCommand throws on non-zero exit code"
            Body = {
                $filePath = Join-Path $PSHOME "powershell.exe"
                $message = Assert-Throws -Action {
                    Invoke-CheckedCommand -FilePath $filePath -ArgumentList @(
                        "-NoProfile",
                        "-Command",
                        "[Console]::Error.WriteLine('boom'); exit 5"
                    )
                } -ExpectedMessage "Process exited with code 5"

                Assert-Contains -ExpectedSubstring "boom" -Actual $message -Message "stderr should be included in the error message."
            }
        },
        @{
            Name = "Invoke-CheckedCommand rejects a missing executable"
            Body = {
                $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N") + ".exe")
                [void](Assert-Throws -Action { Invoke-CheckedCommand -FilePath $missingPath } -ExpectedMessage "")
            }
        }
    )
}

function Invoke-ProjectEnvironmentTests {
    param(
        [string]$ModulePath = (Join-Path $PSScriptRoot "..\lib\ProjectEnvironment.psm1"),
        [string]$ManifestPath = (Join-Path $PSScriptRoot "..\config\bootstrap-manifest.json")
    )

    Remove-Module ProjectEnvironment -ErrorAction SilentlyContinue
    Import-Module $ModulePath -Force

    $tests = Get-ProjectEnvironmentTests -ModulePath $ModulePath -ManifestPath $ManifestPath
    $results = @()

    foreach ($test in $tests) {
        try {
            & $test.Body
            $results += [pscustomobject]@{
                Name = $test.Name
                Passed = $true
                Error = $null
            }
        } catch {
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
