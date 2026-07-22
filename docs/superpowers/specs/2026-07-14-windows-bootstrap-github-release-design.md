# Windows 一键环境与 GitHub 发布设计

## 目标

将当前交通标志识别项目整理为可公开维护、可在其他 Windows 10/11 x64
设备上复现运行的仓库。运行方案不依赖 Microsoft Store、WSL、Docker、
Windows Update、PostgreSQL、Redis 或 MinIO，优先使用 NVIDIA GPU，并在硬件
或驱动不满足要求时自动回退到 CPU。

## 发布边界

- Git 只包含源代码、依赖锁、配置模板、自动化脚本、测试和文档。
- `.runtime/`、`.venv/`、`models/`、训练集、训练输出、数据库、上传文件、日志、
  本地配置、压缩包、参考项目和临时抓取文件不得进入 Git。
- 模型权重作为 GitHub Release `models-v1` 的附件发布，不提交到 Git 历史。
- 默认检测模型为当前本机实际使用、效果更好的 42 类 YOLO11s TT100K 权重；
  项目自训的 common-45 YOLO11n 权重作为可选附件；默认分类模型为 GTSRB
  YOLO11n-cls 权重。
- 每个发布附件在仓库内模型清单中记录文件名、用途、大小、SHA-256、来源和
  许可证说明。安装脚本必须在使用前验证 SHA-256。
- 不重写或强制推送 GitHub 历史。发布前获取远端 `main`，只有在正常合并或
  快进成立时才推送。

## 运行时架构

### 环境引导

`scripts/bootstrap-windows.ps1` 是唯一的一键入口。默认执行以下步骤：

1. 验证 Windows x64、PowerShell、TLS 1.2、磁盘空间和网络访问。
2. 在 `.runtime/downloads/` 下载固定版本的 Python x64 官方安装器和 Node.js
   x64 官方 ZIP，并验证仓库清单中固定的 SHA-256。
3. 将 Python 安装到 `.runtime/python/`，将 Node.js 解压到 `.runtime/node/`；
   不要求管理员权限，不注册系统级 PATH，不影响机器上已有运行时。
4. 使用项目 Python 创建 `backend/.venv`，升级 pip，并安装后端依赖。
5. `-Device auto` 通过 `nvidia-smi` 和 PyTorch CUDA 自检选择 GPU 或 CPU 依赖；
   `-Device gpu` 在 CUDA 自检失败时直接报错；`-Device cpu` 始终安装 CPU 依赖。
6. 使用项目 Node.js 执行 `npm ci`，严格按提交的 `package-lock.json` 安装前端。
7. 从 GitHub Release 下载模型到 `models/` 并验证哈希。
8. 从 `backend/.env.local.example` 生成 `backend/.env`。脚本生成随机 JWT 密钥，
   写入相对模型路径，并且不覆盖已有 `.env`，除非显式传入 `-ForceConfig`。
9. 运行环境诊断；只有全部必需检查通过才报告安装成功。

脚本支持 `-Device auto|gpu|cpu`、`-SkipRuntimeDownload`、`-SkipModels`、
`-ForceConfig` 和 `-Start`。重复执行必须保持幂等：已通过哈希验证的下载、正确
版本的运行时、现有虚拟环境和 `node_modules` 可以复用，损坏或版本不匹配的项
必须重建。

### 依赖组织

后端依赖拆分为：

- `backend/requirements-core.txt`：FastAPI、Ultralytics、SAHI、数据库、本地服务、
  认证和测试依赖，不包含 PyTorch wheel 来源。
- `backend/requirements-gpu.txt`：引用 core，并固定 CUDA 12.8 的 torch/torchvision。
- `backend/requirements-cpu.txt`：引用 core，并固定 CPU torch/torchvision。
- `backend/requirements.txt`：兼容现有开发流程，引用 GPU 依赖文件。

前端提交 `frontend/package-lock.json`，安装和 CI 均使用 `npm ci`。

### 启停和诊断

- `scripts/doctor.ps1` 输出 Python、Node.js、PyTorch、CUDA、模型、配置、端口和
  前后端依赖状态；任一必需项失败时返回非零退出码。
- `scripts/start.ps1` 使用项目私有运行时启动 FastAPI 和 Vite，将 PID、标准输出
  和错误日志写入 `.runtime/state/`，等待后端健康检查和前端端口就绪后输出 URL。
- `scripts/stop.ps1` 只终止 PID 文件中记录、且可执行路径或命令行与本项目匹配的
  进程。过期 PID 文件直接清理，不按端口盲目结束进程。

## 配置和模型数据流

安装清单保存固定的运行时 URL、哈希、Release 标签、模型 URL 和哈希。引导脚本
读取清单，完成下载和校验后生成本地配置。应用只从 `models/` 读取已验证权重：

- 默认 `YOLO_MODEL_PATH` 指向 42 类 YOLO11s 检测权重，并启用现有 TT100K
  common-45 类别规范化。
- `GTSRB_MODEL_PATH` 指向 GTSRB YOLO11n-cls 权重。
- `YOLO_DEVICE` 和 `GTSRB_DEVICE` 均写为 `auto`，运行时由应用再次确认 GPU。
- common-45 YOLO11n 模型保留为文档化的可选切换项，不替换效果更好的默认模型。

模型下载失败、哈希不符或权重加载失败时，脚本必须给出具体文件和恢复命令，
不得静默切换到通用 COCO 模型并声称交通标志功能可用。

## 仓库整理

- 重写根 README，说明功能、截图、系统要求、一键命令、访问地址、模型来源、
  GPU/CPU 行为、测试命令和已知限制。
- 新增 Windows 安装与故障排查文档；保留训练文档，但将本机绝对路径改成仓库
  相对路径。
- 修正 `.gitignore`，跟踪依赖锁和 GitHub 配置，同时排除所有本地运行产物以及
  当前未跟踪的大型压缩包、参考项目和临时文件。
- 添加 GitHub Actions CI：后端使用 CPU 依赖运行测试，前端运行 lint、测试和
  build；CI 不下载业务模型，也不需要 GPU。
- 添加 Issue 模板和 Pull Request 模板。仓库描述设置为 Windows 本地运行的
  YOLO11 交通标志检测平台，Topics 包含 `yolo11`、`traffic-sign-detection`、
  `fastapi`、`react`、`pytorch`、`computer-vision`。
- 仓库源代码许可、Ultralytics 义务、训练数据条款和模型再分发资格分别说明。
  TT100K 按官方 CC BY-NC 条款署名并引用；本次只发布仓库所有者明确指定的 42 类检查点，不发布项目训练的 common-45 检查点。

## GitHub 发布流程

1. 在当前功能分支完成实现并通过全部检查。
2. 扫描待提交文件，确认无 `.env`、令牌、数据库、日志、数据集、权重或大文件。
3. 获取远端 `main`，正常合并当前分支并再次运行关键测试。
4. 推送功能分支和 `main`，不使用 `--force`。
5. 使用已登录的 GitHub CLI 更新仓库描述、Topics、Issues 配置和其他元数据。
6. 仅为来源链和再分发授权均已核验的模型创建或更新 `models-v1` Release；
   未通过发布门禁的检查点不得上传。
7. 从 GitHub 新目录克隆仓库，执行引导脚本的全新安装冒烟测试。

如果 GitHub CLI 未登录，代码推送可在凭据管理器可用时继续，但元数据和 Release
步骤必须明确报告为未完成，不能把本地文件复制成功视为发布成功。

## 错误处理与安全

- 所有脚本启用严格错误处理，外部命令返回非零时立即停止并保留可诊断日志。
- 下载只允许 HTTPS，固定版本和固定 SHA-256；不执行未校验的安装器或脚本。
- 日志不得打印 JWT、API 密钥或完整认证请求头。
- 生成配置前验证目标路径位于仓库内；脚本不得递归删除仓库外路径。
- 启停脚本验证 PID 身份，防止终止无关进程。
- Git 发布前同时检查 Git 状态、被忽略文件和已跟踪对象大小。

## 验证策略

- PowerShell 解析测试覆盖所有新脚本，确保兼容 Windows PowerShell 5.1。
- 可离线执行的脚本测试覆盖设备选择、版本比较、哈希验证、配置生成、幂等执行、
  PID 身份校验和失败退出码。
- `doctor.ps1` 在当前 GPU 环境必须确认 CUDA 可用，在强制 CPU 模式下必须确认
  CPU wheel 和推理设备选择正确。
- 后端运行完整 pytest 和 `pip check`；前端运行 lint、Vitest 和生产构建。
- 使用 `Test/` 中现有图片完成登录、上传、中文标签结果的 API/UI 冒烟测试。
- 发布后从干净目录验证克隆、模型下载、启动、健康检查和停止完整闭环。

## 完成标准

- 新设备只需克隆仓库并运行一条 PowerShell 命令即可完成环境、依赖、配置和模型
  准备，不需要 Microsoft Store、WSL、Docker 或管理员级系统改动。
- GPU 设备使用 CUDA，非 GPU 设备明确回退 CPU；两种模式均通过诊断。
- GitHub `main` 包含整理后的项目，CI 通过，仓库元数据完整，Release 模型可下载
  且哈希一致。
- 本地未跟踪数据和大型文件保持原状且未上传，Git 历史中不存在密钥和模型权重。
