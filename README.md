# TrafficAgent

TrafficAgent 是面向交通场景的本地交通标志识别应用。它用 FastAPI、React 和 YOLO11 提供完整街景检测、单标志裁剪图分类，以及图片、批量图片、视频和摄像头工作流；结果包含规范化类别编号、中文含义、置信度和标注图。

## 功能

- **TT100K 街景检测**：默认 42 类 YOLO11s 检测器对图片街景按 `512 x 512`、重叠率 `0.2` 使用 SAHI 定位小目标，并把原生类别映射到项目统一的 common-45 编号；视频和摄像头为满足实时性使用整帧推理，不启用 SAHI 切片。
- **GTSRB 裁剪图分类**：YOLO11n-cls 对单个交通标志裁剪图执行 43 类分类；`auto` 模式在图片最长边不超过 512 像素时选择分类器，否则选择检测器。
- **鉴权工作流**：本地账号登录后，支持单图、最多 20 张图片或 ZIP 的批量任务、异步视频采样检测，以及通过 WebSocket 处理浏览器摄像头帧。
- **中文语义**：TT100K 和 GTSRB 结果均返回中文显示名，便于直接阅读限速、禁令、警告和指示标志。
- **本地优先**：`auto` 优先使用可用的 NVIDIA GPU；CUDA 自检失败时自动回退到 CPU 并安装对应依赖。开发数据保存在本地 SQLite，不要求 PostgreSQL、Redis 或 MinIO。

当前后端尚未实现交通信号灯状态推理。响应中的 `traffic_lights` 仍为空数组；GTSRB 的“交通信号灯”类别只表示交通标志牌分类，不代表红黄绿灯状态识别。

## Windows 要求

- Windows 10/11 x64。
- Windows PowerShell 5.1 或更高版本。
- GPU 模式至少 12 GB 可用磁盘空间；CPU 模式至少 6 GB。
- GPU 模式需要当前可用的 NVIDIA 驱动，并能在 PowerShell 中运行 `nvidia-smi`。

安装不依赖 Microsoft Store、WSL、Docker 或管理员权限。Python 3.10.11 和 Node.js 24.18.0 安装在仓库内，不修改系统 PATH。

## 一条命令启动

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto -Start
```

脚本会准备项目内运行时、后端虚拟环境、锁定的前端依赖、本地配置和默认模型，然后启动服务。默认检测器是 42 类 `reference42` 权重；模型附件的文件名、大小、哈希和适用条款以 [models-v1 发布契约](docs/releases/models-v1.md) 为准。

启动后访问：

- 前端：`http://127.0.0.1:5173`
- API 文档：`http://127.0.0.1:8000/docs`

首次使用先在前端注册本地账号。图片、视频和摄像头接口均要求登录。

## 日常命令

以下命令均从仓库根目录运行：

```powershell
# 诊断环境；-Json 可输出机器可读结果
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device auto

# 启动或停止由本项目管理的前后端进程
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1
```

`stop.ps1` 会核对 PID、启动时间、可执行文件和项目命令标记，只停止匹配的项目进程；它不会按端口结束其他程序。

强制设备选择：

```powershell
# 即使存在 NVIDIA GPU 也安装 CPU 版 PyTorch
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device cpu -Start

# 必须通过 nvidia-smi 和 PyTorch CUDA 自检，否则失败
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device gpu -Start
```

## 模型选择

| 文件 | 用途 | 状态 |
| --- | --- | --- |
| `models/tt100k-yolo11s-reference42.pt` | TT100K 42 类街景检测 + common-45 映射 | 默认检测器；Release 自动下载 |
| `models/gtsrb-yolo11n-cls.pt` | GTSRB 43 类裁剪图分类 | 默认分类器；Release 自动下载 |

默认 42 类检测器没有训练 `ph5`、`w32`、`wo`，因此不能可靠检测这三类。项目训练的 common-45 权重不属于本发布版本，也不会被 bootstrap 下载。

## 测试

```powershell
# PowerShell 离线契约测试
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\run.ps1

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
```

## 目录

- `backend/`：FastAPI API、SQLite 数据、检测与分类服务。
- `frontend/`：React/Vite 界面，包括图片、视频和摄像头页面。
- `scripts/`：Windows 引导、诊断、启停、训练和评估脚本。
- `models/`：本地模型权重，不提交到 Git。
- `training/`：本地数据准备、训练输出和评估结果，不提交大型产物。
- `.runtime/`：项目内 Python/Node 运行时、下载缓存、日志和进程状态。

## 文档

- [Windows 安装与故障排查](docs/windows-setup.md)
- [本地开发、识别、训练与评估](docs/local-development.md)
- [models-v1 模型发布契约](docs/releases/models-v1.md)
- [第三方说明](THIRD_PARTY_NOTICES.md)

## 许可证

仓库源代码按 [GNU Affero General Public License v3.0](LICENSE) 发布。该软件许可不授予 TT100K 数据或 TT100K 派生权重的使用、商业使用或再分发权。TT100K 官方页面将数据集标为 [CC BY-NC](https://cg.cs.tsinghua.edu.cn/traffic-sign/)；Ultralytics 组件另受其 AGPL-3.0 或企业许可要求约束。模型发布必须同时满足软件、训练数据和模型来源条款，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。
