# Windows 原生安装与运行

本文档适用于从仓库根目录运行项目的 Windows x64 环境。安装流程只使用 Windows PowerShell 和项目内目录，不需要 Microsoft Store、WSL、Docker 或管理员权限，也不会修改系统级 Python、Node.js 或 CUDA 安装。

## 运行要求

- Windows x64。
- Windows PowerShell 5.1。以下命令显式使用 `powershell.exe`，即使当前终端是 PowerShell 7 也会进入 Windows PowerShell 5.1。
- GPU 模式至少保留 `12 GB` 可用磁盘空间；CPU 模式至少保留 `6 GB`。
- GPU 模式需要可正常运行的 NVIDIA 驱动，并且 `nvidia-smi.exe` 位于 `PATH`。引导脚本不会安装或更新显卡驱动。
- 能访问清单中列出的 Python、Node.js 和 GitHub Release HTTPS 地址。

在仓库根目录检查基础环境：

```powershell
$PSVersionTable.PSVersion
[Environment]::Is64BitOperatingSystem
Get-PSDrive -Name (Get-Location).Drive.Name
Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
nvidia-smi.exe
```

CPU 模式不要求 `nvidia-smi.exe`。如果最后一条命令失败，不要强制选择 GPU；先使用 CPU 模式，或在项目外修复驱动后再重试。

## 预览安装计划

`-PlanOnly` 只输出 JSON 计划，不下载、不安装、不生成配置，也不启动服务。建议首次执行或排障时先预览：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 `
  -Device auto `
  -PlanOnly
```

计划会列出最终设备、运行时版本、依赖文件、模型、配置动作以及是否启动服务。

## 执行引导

三种设备模式：

```powershell
# 自动：检测到 nvidia-smi 后先尝试 GPU；CUDA 自检失败时自动重建为 CPU 环境
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto

# 强制 GPU：CUDA 自检失败即停止，不回退 CPU
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device gpu

# 强制 CPU：不安装 GPU 版 Python 依赖
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device cpu
```

引导脚本按 `scripts/config/bootstrap-manifest.json` 下载并校验固定版本的 Python 和 Node.js，在项目中创建 `.runtime/`、`backend/.venv/`、`frontend/node_modules/` 和默认 `models/`，再生成本地 `backend/.env`。已有 `backend/.env` 默认保留；`-ForceConfig` 会替换它，并生成新的随机 JWT 密钥，因此使用前应先备份自己的配置。

安装完成后直接启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 `
  -Device auto `
  -Start
```

## 环境诊断

人类可读输出：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device auto
```

供脚本处理的压缩 JSON 输出：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 `
  -Device auto `
  -Json
```

`doctor.ps1` 检查 Windows x64、磁盘、运行时版本、虚拟环境、`pip check`、Torch/CUDA、前端依赖、本地配置、SQLite 目录、模型哈希和默认端口。强制 GPU 或 CPU 安装后，应把 `-Device` 改为对应值。

## 启动、访问与停止

推荐通过托管脚本启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1
```

默认地址：

- 前端：`http://127.0.0.1:5173`
- API 文档：`http://127.0.0.1:8000/docs`
- 基础健康检查：`http://127.0.0.1:8000/api/health`
- 详细健康检查：`http://127.0.0.1:8000/api/health/detail`

停止由该仓库启动的服务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1
```

日志保存在 `.runtime/logs/`，后端和前端各有 stdout/stderr 文件；进程状态保存在 `.runtime/state/`。例如：

```powershell
Get-Content .\.runtime\logs\backend.stderr.log -Tail 100
Get-Content .\.runtime\logs\frontend.stderr.log -Tail 100
Get-Content .\.runtime\state\backend.json
Get-Content .\.runtime\state\frontend.json
```

不要手工伪造状态文件。`stop.ps1` 会同时核对项目根目录、角色、PID、可执行文件路径、进程启动时间和带项目角色标记的命令行；只有全部匹配才会终止进程。PID 已复用、记录损坏或身份不一致时会报错，不会终止陌生进程。

## 视频检测与播放

登录前端后点击“视频检测”，选择不超过 `50 MB` 的 MP4、AVI、MOV、MKV、WMV 或 FLV 文件。任务执行期间会显示进度和不断更新的带框预览；完成后结果卡片切换为可拖动进度、暂停和全屏播放的 H.264 MP4，并提供下载、类别统计和关键帧。输出视频按当前需求不保留音轨。

一键安装生成的新配置默认使用 `YOLO_IMAGE_SIZE=1280`、`VIDEO_FRAME_SAMPLE_RATE=1` 和 `VIDEO_MAX_FRAMES=0`，即以较高输入尺寸逐帧检测完整时间线，减少小交通标志漏检。已有 `backend/.env` 不会被自动覆盖；需要采用新默认值时手工更新这三项，或在备份自定义配置后使用 `-ForceConfig` 重新生成。GPU 可用时优先使用 `-Device auto`；CPU 同样可运行，但长视频处理会明显更慢。

## 常见问题

### 代理变量错误或本地请求被代理

先查看当前进程和用户级代理变量：

```powershell
Get-ChildItem Env: | Where-Object Name -Match '^(HTTP|HTTPS|ALL|NO)_PROXY$'
[Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
[Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
```

代理有效时，至少让本地地址绕过代理：

```powershell
$env:NO_PROXY = '127.0.0.1,localhost'
```

如果代理地址已经失效，清除当前 PowerShell 进程及当前用户的代理变量，然后新开一个终端：

```powershell
$proxyNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
foreach ($name in $proxyNames) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable($name, $null, 'User')
}
```

只清除确认损坏的代理配置；公司网络必须使用代理时，应改成正确地址并保留 `NO_PROXY=127.0.0.1,localhost`。

### 下载失败和重试

每个下载最多自动尝试三次，并短暂退避。网络恢复后可以原样重跑引导命令；哈希正确的项目内缓存会被复用。不要关闭 HTTPS 校验，也不要改用来源不明的镜像。

### SHA-256 不匹配

先读取清单中的 URL、文件名和预期哈希，再检查实际文件：

```powershell
$manifest = Get-Content .\scripts\config\bootstrap-manifest.json -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest.runtime
$manifest.release.models | Format-Table filename, sha256, url

$runtimeFile = Join-Path '.\.runtime\downloads' $manifest.runtime.node.filename
if (Test-Path -LiteralPath $runtimeFile) {
    Get-FileHash -LiteralPath $runtimeFile -Algorithm SHA256
}
```

确认某个缓存确实不完整或哈希不符后，只删除该项目中的对应文件，再重跑引导；不要清理系统缓存或其他项目：

```powershell
Remove-Item -LiteralPath "$runtimeFile.partial" -Force -ErrorAction SilentlyContinue
# 仅当上一步核对确认 $runtimeFile 哈希不符时执行：
Remove-Item -LiteralPath $runtimeFile -Force
```

模型同样位于 `models/`，临时文件后缀为 `.partial`。按清单选中具体模型并核对后，只删除那个 `.partial` 或哈希不符的模型文件。

### NVIDIA 或 CUDA 自检失败

依次检查驱动、Torch 构建和 CUDA 可用性：

```powershell
nvidia-smi.exe
.\backend\.venv\Scripts\python.exe -c "import torch; print(torch.__version__); print(torch.version.cuda); print(torch.cuda.is_available())"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device gpu
```

显式 GPU 模式要求 Torch 为清单依赖指定的 CUDA 构建，并且 `torch.cuda.is_available()` 返回 `True`。本项目不要求单独安装 CUDA Toolkit，但要求主机 NVIDIA 驱动与所安装的 Torch CUDA 构建兼容。

需要强制改用 CPU 时：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 `
  -Device cpu `
  -ForceConfig
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device cpu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1
```

`-ForceConfig` 会替换 `backend/.env`，有自定义配置时先备份。

### 模型 Release 缺失或哈希不符

模型下载以 `scripts/config/bootstrap-manifest.json` 中的仓库、Release 标签、文件名、字节数和 SHA-256 为准。遇到 `404`、Release 文件缺失或哈希不符时：

1. 确认当前代码与清单来自同一版本。
2. 确认清单 URL 对应的 Release 和文件名实际存在。
3. 使用 `Get-FileHash` 核对下载文件，不要绕过哈希检查。
4. Release 尚未发布或清单哈希错误时停止安装，等待发布方修复；不要把未知权重改名后冒充默认模型。

### 端口被占用

先确认监听者身份，不要直接结束陌生进程：

```powershell
$listeners = Get-NetTCPConnection -State Listen -LocalPort 8000,5173 -ErrorAction SilentlyContinue
$listeners | Select-Object LocalAddress, LocalPort, OwningProcess
$listeners | ForEach-Object { Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue }
```

如果占用者不是本项目托管进程，保留它并改用其他端口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1 `
  -BackendPort 18000 `
  -FrontendPort 15173
```

此时前端为 `http://127.0.0.1:15173`，API 文档为 `http://127.0.0.1:18000/docs`，启动脚本会自动把前端代理指向新后端端口。`start.ps1` 只会复用身份完全匹配的既有托管实例，否则会拒绝启动。

## 项目内干净重装

先停止服务，并确认当前目录确实是仓库根目录。`backend/data/` 中的 SQLite 数据库和 `backend/uploads/` 中的上传文件、检测结果属于用户数据；清理前应备份，且下面的默认清理不会删除它们。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1

Remove-Item -LiteralPath .\.runtime -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath .\backend\.venv -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath .\frontend\node_modules -Recurse -Force -ErrorAction SilentlyContinue

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto
```

只有在某个清单管理的模型缺失、损坏或需要重新下载时，才删除那个具体文件。下面的命令仅删除两个默认模型，保留可选模型和用户训练权重：

```powershell
$manifest = Get-Content .\scripts\config\bootstrap-manifest.json -Raw -Encoding UTF8 | ConvertFrom-Json
$defaultModels = @($manifest.release.models | Where-Object { ([string]$_.purpose).StartsWith('default ') })
foreach ($model in $defaultModels) {
    $path = Join-Path .\models ([string]$model.filename)
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$path.partial" -Force -ErrorAction SilentlyContinue
}
```

不要递归删除整个 `models/`，也不要把清理范围扩大到用户目录、系统 Python/Node、全局 npm/pip 缓存或其他仓库；不要删除 `backend/data/` 和 `backend/uploads/`。
