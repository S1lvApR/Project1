# TrafficAgent 完整依赖说明

本文档说明 TrafficAgent 各部分所需的系统、运行时、软件包、模型、数据集和外部服务。默认目标是无需 WSL、Docker、Microsoft Store 或管理员权限即可在 Windows 10/11 x64 上运行。

版本的机器可读来源是 [bootstrap manifest](../scripts/config/bootstrap-manifest.json)、[Python requirements](../backend/requirements-core.txt)、[Python 完整锁文件](../backend/requirements-common.lock)、[前端 package.json](../frontend/package.json) 和 [npm 完整锁文件](../frontend/package-lock.json)。本文档列出所有直接依赖；传递依赖不重复抄写，以免形成第二份易过期的锁文件。

## 选择运行模式

| 场景 | 必需部分 | 计算依赖 | 数据与外部服务 |
| --- | --- | --- | --- |
| Windows 本地 GPU 完整应用 | Python、Node.js、后端、前端、两个模型 | CUDA 12.8 PyTorch wheel、兼容的 NVIDIA 驱动 | SQLite 本地文件；不需要 PostgreSQL、Redis、MinIO |
| Windows 本地 CPU 完整应用 | Python、Node.js、后端、前端、两个模型 | CPU PyTorch wheel | SQLite 本地文件；不需要 PostgreSQL、Redis、MinIO |
| 仅后端开发 | Python、后端依赖、按设备选择 PyTorch、模型 | CPU 或 GPU | 默认 SQLite；API 默认监听 `8000` |
| 仅前端开发 | Node.js、npm 依赖 | 不需要 PyTorch 或模型 | 后端 API 仍需由本机或其他地址提供；Vite 默认监听 `5173` |
| 数据准备、训练与评估 | Python、后端依赖、数据集、初始/待评估权重 | 建议 GPU；训练脚本默认面向 CUDA | 本地数据集和训练目录；不需要前端 |
| 自动化测试 | Python CPU 依赖、Node.js/npm、PowerShell | CI 后端使用 CPU PyTorch | 单元测试使用临时 SQLite 和假模型，不下载业务权重 |
| 生产模式 | Python、后端、前端构建产物、模型 | 按服务器选择 CPU 或 GPU | PostgreSQL 必需；Redis 和 MinIO 默认启用，除非显式关闭 |

## 主机与系统依赖

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| 操作系统 | Windows 10/11 x64 | 一键引导脚本只支持 x64 Windows；后端和前端 CI 也在 Linux 上验证 |
| PowerShell | Windows PowerShell 5.1 或更高版本 | 执行 bootstrap、doctor、start、stop、训练包装器和契约测试 |
| 磁盘空间 | GPU 模式至少 `12 GB`；CPU 模式至少 `6 GB` | 包含仓库内运行时、虚拟环境、npm 模块、模型和缓存；训练数据另计 |
| 浏览器 | 当前版 Chrome 或 Edge | 需要 JavaScript、WebSocket、摄像头权限和 H.264 MP4 播放能力 |
| 本地端口 | `8000`、`5173` | FastAPI 与 Vite；端口被占用时启动脚本会拒绝覆盖未知进程 |
| GPU | 可选 NVIDIA GPU | `-Device auto` 优先 GPU；`-Device gpu` 要求 `nvidia-smi` 和 `torch.cuda.is_available()` 成功 |
| NVIDIA 驱动 | GPU 模式必需 | 必须兼容 PyTorch 的 CUDA 12.8 wheel；仓库不固定驱动版本，使用目标机器支持的当前驱动 |
| 管理员权限 | 不需要 | Python、Node.js、虚拟环境和缓存均安装到仓库内 |

GPU wheel 已包含所需 CUDA 用户态运行库，因此运行和常规训练不要求单独安装 CUDA Toolkit。视频编码由 `imageio-ffmpeg` 自带二进制提供，不要求安装 system FFmpeg。默认本地流程也不要求 WSL 或 Docker。

## 下载与网络

首次 bootstrap 可能访问以下服务：

| 地址 | 用途 |
| --- | --- |
| `python.org` | 下载固定的 Python 安装程序 |
| `nodejs.org` | 下载固定的 Node.js 压缩包 |
| `pypi.org` | 安装后端通用 Python 包 |
| `download.pytorch.org` | 安装 CPU 或 CUDA 12.8 PyTorch wheel |
| `registry.npmjs.org` | 按 `package-lock.json` 执行 `npm ci` |
| `github.com/Dman-s/Project1/releases` | 下载并校验两个模型附件 |

代理、下载重试、离线复用和哈希错误处理见 [Windows 安装与故障排查](windows-setup.md)。应用启动后的默认本地推理不需要云 API。

## 固定运行时

版本和下载哈希来自 `scripts/config/bootstrap-manifest.json`。

| 运行时 | 固定版本 | 文件 | SHA-256 | 安装位置 |
| --- | --- | --- | --- | --- |
| Python | `3.10.11` | `python-3.10.11-amd64.exe` | `D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B` | `.runtime/python`，后端环境位于 `backend/.venv` |
| Node.js | `24.18.0` | `node-v24.18.0-win-x64.zip` | `0AE68406B42D7725661DA979B1403EC9926DA205C6770827F33AAC9D8F26E821` | `.runtime/node` |

npm 随固定 Node.js 压缩包提供，不单独下载或加入系统 PATH。当前归档中的 npm 为 `11.16.0`，但仓库契约固定的是 Node.js 归档及其哈希；前端依赖版本由 `package-lock.json` 固定。

## PyTorch 与计算设备

| 模式 | 入口文件 | 固定依赖 | 下载源 |
| --- | --- | --- | --- |
| CPU | `backend/requirements-cpu.txt` | `torch==2.11.0+cpu`、`torchvision==0.26.0+cpu` | `https://download.pytorch.org/whl/cpu` |
| GPU | `backend/requirements-gpu.txt` | `torch==2.11.0+cu128`、`torchvision==0.26.0+cu128` | `https://download.pytorch.org/whl/cu128` |
| 兼容默认入口 | `backend/requirements.txt` | 引用 GPU 入口 | 与 GPU 模式相同 |

`-Device auto` 检测到 NVIDIA 后先安装 GPU 入口并执行 CUDA 自检；失败时重建后端虚拟环境并回退 CPU。`-Device gpu` 的 CUDA 自检失败属于致命错误，`-Device cpu` 始终使用 CPU wheel。

## 后端直接依赖

`backend/requirements-core.txt` 列出所有非设备专用的直接依赖。bootstrap 无论本地或生产模式都会安装这些包，但生产客户端包在本地模式不会连接外部服务。

### Web 与 API

| 包 | 版本 | 作用 | 使用范围 |
| --- | --- | --- | --- |
| `fastapi` | `0.139.0` | HTTP API、依赖注入、OpenAPI | 后端运行 |
| `starlette` | `1.3.1` | ASGI、静态文件、WebSocket 基础 | 后端运行 |
| `uvicorn[standard]` | `0.24.0.post1` | ASGI 服务进程 | 后端运行 |
| `python-multipart` | `0.0.32` | 图片、ZIP 和视频表单上传 | 后端运行 |

### 检测、图像与视频

| 包 | 版本 | 作用 | 使用范围 |
| --- | --- | --- | --- |
| `ultralytics` | `8.3.0` | YOLO 检测、分类、训练和评估 | 推理与训练 |
| `sahi` | `0.11.18` | TT100K 街景小目标切片检测 | 图片检测 |
| `opencv-python` | `4.9.0.80` | 图像编解码、视频读取、绘框 | 图片、视频、摄像头 |
| `Pillow` | `12.3.0` | RGB 图像、中文标注、分类输入 | 推理与标注 |
| `imageio-ffmpeg` | `0.6.0` | 提供 FFmpeg 并编码 H.264/yuv420p MP4 | 视频检测 |

### 数据库与迁移

| 包 | 版本 | 作用 | 使用范围 |
| --- | --- | --- | --- |
| `sqlalchemy` | `2.0.0` | ORM、SQLite/PostgreSQL 会话 | 所有后端模式 |
| `psycopg2-binary` | `2.9.9` | PostgreSQL 客户端驱动 | 生产模式 |
| `pgvector` | `0.3.0` | PostgreSQL vector 类型兼容支持 | 生产兼容；当前本地识别流程不使用向量列 |
| `alembic` | `1.13.0` | 生产数据库迁移 | 生产部署与数据库开发 |

### 缓存与对象存储

| 包 | 版本 | 作用 | 使用范围 |
| --- | --- | --- | --- |
| `redis` | `5.0.0` | Redis 客户端和健康检查 | 生产模式；本地默认禁用 |
| `minio` | `7.2.0` | MinIO 客户端、桶和对象访问 | 生产模式；本地默认禁用 |

### 认证、配置与工具

| 包 | 版本 | 作用 | 使用范围 |
| --- | --- | --- | --- |
| `PyJWT[crypto]` | `2.13.0` | JWT 签发、验证和加密后端 | 用户认证 |
| `passlib[bcrypt]` | `1.7.4` | 密码哈希接口 | 用户认证 |
| `pydantic` | `2.9.2` | 请求、响应和领域数据验证 | 后端运行 |
| `pydantic-settings` | `2.4.0` | `.env` 和环境变量设置 | 后端运行 |
| `httpx` | `0.27.0` | HTTP 客户端与 API 测试 | 后端与测试 |
| `python-dotenv` | `1.2.2` | `.env` 兼容加载 | 后端配置 |
| `apscheduler` | `3.10.4` | 本地定时清理任务 | 后端运行 |

### 测试

| 包 | 版本 | 作用 |
| --- | --- | --- |
| `pytest` | `9.1.1` | 后端单元与集成测试 |
| `pytest-asyncio` | `1.4.0` | 异步 API/WebSocket 测试支持 |

完整的 93 个已解析非设备 Python 包及条件标记位于 `backend/requirements-common.lock`。该锁文件包含直接依赖的传递图，例如 NumPy、pandas、SciPy、matplotlib、cryptography、bcrypt、requests、watchfiles 和 websockets；不要在本文档中手工维护第二份传递依赖清单。

## 前端直接依赖

声明范围来自 `frontend/package.json`，精确解析版本和完整传递图来自 `frontend/package-lock.json`。安装必须使用仓库内 npm 执行 `npm ci`。

### 运行依赖

| 包 | 声明范围 | 作用 |
| --- | --- | --- |
| `clsx` | `^2.1.1` | 条件 CSS 类组合 |
| `lucide-react` | `^0.511.0` | 界面图标 |
| `react` | `^18.3.1` | 组件运行时 |
| `react-dom` | `^18.3.1` | 浏览器 DOM 渲染 |
| `react-router-dom` | `^7.3.0` | 页面路由 |
| `tailwind-merge` | `^3.0.2` | Tailwind 类冲突合并 |
| `zustand` | `^5.0.14` | 登录、会话和检测状态管理 |

### 开发、样式、构建与测试依赖

| 包 | 声明范围 | 作用 |
| --- | --- | --- |
| `@eslint/js` | `^9.25.0` | ESLint JavaScript 规则 |
| `@vitejs/plugin-react` | `^4.4.1` | Vite React 转换与热更新 |
| `autoprefixer` | `^10.4.21` | CSS 浏览器前缀 |
| `babel-plugin-react-dev-locator` | `^1.0.0` | 开发环境组件定位 |
| `eslint` | `^9.25.0` | 静态检查 |
| `eslint-plugin-react-hooks` | `^5.2.0` | React Hooks 规则 |
| `eslint-plugin-react-refresh` | `^0.4.19` | React Refresh 规则 |
| `globals` | `^16.0.0` | ESLint 运行环境全局变量 |
| `postcss` | `^8.5.3` | CSS 转换流水线 |
| `sass` | `^1.77.8` | SCSS 编译 |
| `tailwindcss` | `^3.4.19` | 原子 CSS 生成 |
| `vite` | `^6.3.5` | 开发服务器和生产构建 |
| `vite-plugin-trae-solo-badge` | `^1.0.0` | 当前 Vite 配置中的开发插件 |
| `@vue/test-utils` | `^2.4.11` | 已声明的测试兼容工具；当前 React 测试未直接导入 |
| `happy-dom` | `^20.10.6` | Vitest 浏览器 DOM 环境 |
| `vitest` | `^4.1.10` | 前端单元与组件测试 |

`package-lock.json` 是 npm 传递依赖和完整性哈希的唯一权威清单。不要用 `npm install` 任意刷新版本；可复现安装使用 `npm ci`。

## 数据与外部服务

### 默认 Windows 本地模式

| 组件 | 配置 | 依赖情况 |
| --- | --- | --- |
| SQLite | `DATABASE_URL=sqlite:///./data/local.db` | Python 标准库自带，不需要额外服务器 |
| 本地上传与结果 | `backend/uploads/` | 使用普通文件系统 |
| 视频状态 | `backend/data/video_status/` | 使用 JSON 状态文件和 SQLite 任务记录 |
| Redis | `REDIS_ENABLED=false` | 不启动、不连接 |
| MinIO | `MINIO_ENABLED=false` | 不启动、不连接 |

### 生产模式

| 服务 | 默认连接 | 客户端依赖 | 说明 |
| --- | --- | --- | --- |
| PostgreSQL | `localhost:5432` | `psycopg2-binary`、SQLAlchemy、Alembic | 生产数据库；仓库没有锁定服务端版本，部署方必须选定版本并执行迁移和验收 |
| Redis | `localhost:6379` | `redis` | 生产模式默认启用；当前代码用于连接与健康检查，服务端版本未锁定 |
| MinIO | `localhost:9000` | `minio` | 生产模式默认启用；需要访问密钥、密钥、桶名和 HTTP/HTTPS 设置，服务端版本未锁定 |

生产部署不应复用示例口令。至少设置随机 `JWT_SECRET_KEY`、数据库凭据、MinIO 凭据、允许来源和服务地址。是否继续使用 Redis/MinIO 可通过 `REDIS_ENABLED`、`MINIO_ENABLED` 显式控制。

### 第三方 API 配置

- `OPENAI_*`、`QWEN_*` 和 `OLLAMA_*` 只存在于宽泛的兼容示例配置中，当前 TrafficAgent 后端设置和交通标志工作流不读取它们，也没有对应 SDK 依赖。
- `BAIDU_API_KEY`、`BAIDU_SECRET_KEY` 是保留的可选设置；当前交通标志、视频和摄像头工作流不要求它们，requirements 中也没有百度 SDK。

## 模型依赖

模型由 bootstrap 从 [models-v1 Release](https://github.com/Dman-s/Project1/releases/tag/models-v1) 下载，写入 `models/`，并在使用前校验精确字节数和 SHA-256。

| 文件 | 字节数 | SHA-256 | 用途与来源 | 许可 |
| --- | ---: | --- | --- | --- |
| `tt100k-yolo11s-reference42.pt` | `19231379` | `E8A0E0F1E5A9004C708D7EEE9EDD97E9E9D0A7986023E96C807D0FFCD3D50F88` | 默认 TT100K 42 类检测器；仓库所有者提供的训练工程 | Ultralytics AGPL-3.0；TT100K CC BY-NC |
| `gtsrb-yolo11n-cls.pt` | `3291010` | `323E5BD1B0DC5D1F6FBB4C487FAF2320DA0DF9C21132DD46C0C94FEE7B33B16C` | 默认 GTSRB 43 类裁剪分类器；Project1 训练 | AGPL-3.0 |

没有这两个模型时，应用界面可以启动，但对应推理请求会返回模型不可用错误。默认检测器未训练 `ph5`、`w32`、`wo`。模型使用、再分发和数据集条款见 [模型发布契约](releases/models-v1.md) 与 [第三方说明](../THIRD_PARTY_NOTICES.md)。

## 数据准备、训练与评估依赖

训练工具复用后端依赖，不需要单独的 training requirements：

| 工作 | 脚本/工具 | 额外输入 |
| --- | --- | --- |
| TT100K 转换 | `backend/tools/prepare_tt100k.py` | TT100K 原始标注、图片和类别配置 |
| GTSRB 转换 | `backend/tools/prepare_gtsrb.py` | GTSRB 训练/测试压缩包或解压目录 |
| TT100K 训练 | `scripts/train-tt100k-gpu.ps1`、`backend/tools/train_yolo.py` | 转换后的 YOLO 数据集、Ultralytics、GPU 推荐 |
| GTSRB 训练 | `scripts/train-gtsrb-gpu.ps1`、`backend/tools/train_gtsrb.py` | 转换后的分类数据集、Ultralytics、GPU 推荐 |
| 评估 | `scripts/evaluate-*.ps1`、`backend/tools/evaluate_*.py` | 数据集 YAML/目录和待评估权重 |
| 模型晋升 | `scripts/check-tt100k-promotion.ps1`、`backend/tools/check_yolo_promotion.py` | 旧/新评估 JSON 和晋升阈值 |

TT100K 和 GTSRB 数据集、训练缓存、`training/runs/` 及大型权重不由 bootstrap 下载，也不提交到 Git。它们所需磁盘空间应在系统依赖的 `6/12 GB` 基础上另行预留。TT100K 数据和派生权重只能在其 CC BY-NC 条款允许的范围内使用。

## 安装命令

### 推荐：一键准备完整应用

```powershell
# 自动优先 GPU，失败后回退 CPU
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto -Start

# 强制 GPU 或 CPU
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device gpu -Start
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device cpu -Start
```

### 仅安装后端依赖

以下命令假设已存在兼容的 Python 3.10 x64；一键脚本会自动创建相同结构。

```powershell
python -m venv .\backend\.venv

# 二选一
& .\backend\.venv\Scripts\python.exe -m pip install -r .\backend\requirements-gpu.txt
& .\backend\.venv\Scripts\python.exe -m pip install -r .\backend\requirements-cpu.txt
```

### 仅安装前端依赖

```powershell
& .\.runtime\node\npm.cmd --prefix .\frontend ci
```

## 验证命令

```powershell
# 环境、设备、模型、配置、端口和依赖诊断
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device auto

# 后端
& .\backend\.venv\Scripts\python.exe -m pytest -q .\backend\tests
& .\backend\.venv\Scripts\python.exe -m pip check

# 前端
Push-Location .\frontend
try {
  & ..\.runtime\node\npm.cmd run lint
  & ..\.runtime\node\npm.cmd run test:run
  & ..\.runtime\node\npm.cmd run build
} finally {
  Pop-Location
}

# Windows bootstrap、doctor、start/stop 契约
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\run.ps1
```

## CI 依赖

`.github/workflows/ci.yml` 使用：

- Ubuntu：Python 3.10、`requirements-cpu.txt`、pytest、pip check 和 pip-audit；
- Ubuntu：Node.js 24、`npm ci`、ESLint、Vitest 和 Vite build；
- Windows：Windows PowerShell，执行离线环境脚本契约测试。

CI 不下载业务模型，不要求 GPU，也不启动 PostgreSQL、Redis 或 MinIO。

## 版本维护位置

| 变更类型 | 必须更新的权威文件 | 同步检查 |
| --- | --- | --- |
| Python/Node 运行时 | `scripts/config/bootstrap-manifest.json` | 下载哈希、bootstrap 测试、本文档 |
| CPU/GPU PyTorch | `backend/requirements-cpu.txt`、`backend/requirements-gpu.txt` | pip 解析、CUDA 自检、本文档 |
| 后端直接包 | `backend/requirements-core.txt` | 重新生成 `requirements-common.lock`、pip check、本文档 |
| 前端直接包 | `frontend/package.json` | 重新生成 `package-lock.json`、`npm ci`、本文档 |
| 模型附件 | bootstrap manifest、GitHub Release | 字节数、SHA-256、发布契约、许可证、本文档 |
| 外部服务 | `backend/app/config/settings.py`、环境模板 | health、部署说明、本文档 |

依赖更新完成后必须运行上一节的全部验证命令。不要只修改本文档或只修改锁文件。
