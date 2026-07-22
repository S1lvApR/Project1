# TrafficAgent

[![CI](https://github.com/Dman-s/Project1/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Dman-s/Project1/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Dman-s/Project1?display_name=tag)](https://github.com/Dman-s/Project1/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
![Python 3.10](https://img.shields.io/badge/Python-3.10-3776AB?logo=python&logoColor=white)
![Node.js 24](https://img.shields.io/badge/Node.js-24-5FA04E?logo=node.js&logoColor=white)

TrafficAgent 是面向交通场景的本地交通标志识别应用。它使用 FastAPI、React 和 YOLO11 处理街景图片、交通标志裁剪图、视频和浏览器摄像头画面，并返回中文含义、置信度和可视化标注结果。

## 快速开始

运行要求：Windows 10/11 x64、Windows PowerShell 5.1 或更高版本；GPU 模式需要可正常执行 `nvidia-smi` 的 NVIDIA 驱动。安装不依赖 Microsoft Store、WSL、Docker 或管理员权限，也不会修改系统 PATH。

在仓库根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto -Start
```

脚本会在仓库内准备 Python 3.10.11、Node.js 24.18.0、后端虚拟环境、锁定的前端依赖、本地配置和默认模型。`auto` 会优先使用可用的 NVIDIA GPU，并在 CUDA 自检失败时回退到 CPU。

启动后访问：

- 应用界面：`http://127.0.0.1:5173`
- API 文档：`http://127.0.0.1:8000/docs`

首次使用请在应用界面注册本地账号。图片、视频和摄像头接口均要求登录。

## 识别能力

| 工作流 | 推理方式 | 输出 |
| --- | --- | --- |
| 街景图片 | 42 类 TT100K YOLO11s；默认使用 `512 x 512`、重叠率 `0.2` 的 SAHI 切片定位小目标 | 检测框、置信度、规范类别和中文含义 |
| 标志裁剪图 | GTSRB YOLO11n-cls；`auto` 在图片最长边不超过 `512` 像素时选择分类器 | 43 类分类结果和中文含义 |
| 视频 | 默认以 `1280` 输入尺寸逐帧检测完整时间线；处理期间持续更新带框预览 | 浏览器可播放和下载的 H.264/yuv420p MP4、统计和关键帧；输出无音轨 |
| 摄像头 | 通过 WebSocket 处理浏览器摄像头帧，GPU 和 CPU 使用独立实时输入尺寸 | 实时标注画面和检测结果 |

TT100K 原生类别会映射到项目稳定的 common-45 编号。视频中的 50 km/h 限速牌还会经过 GTSRB 裁剪分类器专项复核，减少被误判为 40、70、80、100 km/h 或解除限速的情况；其他数字类别不会被跨数据集结果覆盖。

> [!IMPORTANT]
> 当前后端不执行红、黄、绿交通信号灯状态推理。响应中的 `traffic_lights` 保持为空数组；GTSRB 的“交通信号灯”类别只表示交通标志牌分类。

## 视频检测

1. 登录后点击输入区上方的“视频检测”，选择不超过 `50 MB` 的 MP4、AVI、MOV、MKV、WMV 或 FLV 文件。
2. 处理期间查看检测进度和不断更新的标注预览；默认逐帧推理且不限制处理帧数。
3. 完成后直接在结果卡片中播放带框视频，或下载 MP4；类别统计和检测关键帧保留在播放器下方。

长视频处理时间取决于显卡性能。GPU 可用时建议使用 `-Device auto` 或 `-Device gpu`。

## 环境管理

以下命令均从仓库根目录运行：

```powershell
# 检查运行时、依赖、模型、端口和计算设备；-Json 输出机器可读结果
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device auto

# 启动或停止由项目管理的前后端进程
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1
```

`stop.ps1` 会核对 PID、启动时间、可执行文件和项目命令标记，只终止身份完全匹配的项目进程，不会按端口结束其他程序。

可在首次安装时强制选择设备：

```powershell
# 即使存在 NVIDIA GPU 也安装 CPU 版 PyTorch
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device cpu -Start

# 必须通过 nvidia-smi 和 PyTorch CUDA 自检，否则安装失败
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device gpu -Start
```

GPU 模式至少预留 `12 GB` 磁盘空间，CPU 模式至少预留 `6 GB`。

## 模型

| 文件 | 用途 | 获取方式 |
| --- | --- | --- |
| `models/tt100k-yolo11s-reference42.pt` | TT100K 42 类街景检测和 common-45 映射 | [models-v1 Release](https://github.com/Dman-s/Project1/releases/tag/models-v1) 或 bootstrap 自动下载 |
| `models/gtsrb-yolo11n-cls.pt` | GTSRB 43 类裁剪图分类 | [models-v1 Release](https://github.com/Dman-s/Project1/releases/tag/models-v1) 或 bootstrap 自动下载 |

默认检测器没有训练 `ph5`、`w32`、`wo`，不能可靠识别这三类。项目训练的 common-45 权重不属于当前发布版本，也不会被 bootstrap 下载。模型文件名、大小、SHA-256 和适用条款见 [models-v1 发布契约](docs/releases/models-v1.md)。

## 验证

```powershell
# Windows 安装和进程治理契约测试
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

GitHub Actions 会在 Windows 和 Linux 上执行对应的后端、前端和 bootstrap 检查。

## 仓库结构

- `backend/`：FastAPI API、SQLite 数据、检测与分类服务。
- `frontend/`：React/Vite 界面，包括图片、视频和摄像头工作流。
- `scripts/`：Windows 引导、诊断、启停、训练和评估脚本。
- `models/`：本地模型权重，不提交到 Git。
- `training/`：本地数据准备、训练输出和评估结果，不提交大型产物。
- `.runtime/`：项目内 Python/Node 运行时、缓存、日志和进程状态。

## 文档

- [完整依赖与运行模式说明](docs/dependencies.md)
- [Windows 安装与故障排查](docs/windows-setup.md)
- [本地开发、识别、训练与评估](docs/local-development.md)
- [TT100K reference42 类别与中文含义](docs/tt100k-reference42.md)
- [models-v1 模型发布契约](docs/releases/models-v1.md)
- [第三方说明](THIRD_PARTY_NOTICES.md)

## 许可证

仓库源代码按 [GNU Affero General Public License v3.0](LICENSE) 发布。该软件许可证不授予 TT100K 数据或 TT100K 派生权重的使用、商业使用或再分发权。TT100K 官方页面将数据集标为 [CC BY-NC](https://cg.cs.tsinghua.edu.cn/traffic-sign/)；Ultralytics 组件另受其 AGPL-3.0 或企业许可要求约束。模型发布必须同时满足软件、训练数据和模型来源条款，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。
