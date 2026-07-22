# 本地开发

除非特别说明，本文所有命令都从仓库根目录执行。Windows 原生首次安装、诊断和故障处理见 `docs/windows-setup.md`。

本地模式不依赖 PostgreSQL、Redis 或 MinIO。后端使用 SQLite，默认数据库为 `backend/data/local.db`；上传文件、标注图和视频处理结果保存在 `backend/uploads/`。这两个目录都可能包含用户数据，不应作为普通依赖缓存删除。

## 引导脚本管理的开发环境

推荐让引导脚本按 `scripts/config/bootstrap-manifest.json` 管理 Python、Node.js、Python 虚拟环境、前端依赖、模型和 `backend/.env`：

```powershell
# 先预览，不修改文件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 `
  -Device auto `
  -PlanOnly

# 安装或修复项目内环境
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto

# 检查运行时、依赖、模型、配置、SQLite 和端口
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Device auto
```

`auto` 会优先尝试可用的 NVIDIA GPU，并在 Torch CUDA 自检失败时回退 CPU；也可以明确传入 `-Device gpu` 或 `-Device cpu`。

### 使用已有 Python 和 Node.js

已有开发环境时，可以禁止下载运行时。Python 和 Node.js 必须与清单中的精确版本一致，且 `node.exe` 与 `npm.cmd` 必须位于同一目录：

```powershell
python --version
node --version
npm --version

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 `
  -Device cpu `
  -SkipRuntimeDownload
```

该命令仍会创建 `backend/.venv`、执行 `npm ci`、下载并校验默认模型、生成缺失的本地配置并运行 doctor。只有 PATH 中存在精确匹配的运行时才会成功。

托管的 `start.ps1` 使用 `.runtime/node/node.exe`。如果已有环境只在 PATH 中提供 Node.js、没有项目内 `.runtime/node/node.exe`，请按下文分别启动后端和前端；已经由普通引导流程安装项目内运行时的环境应优先使用 `start.ps1`。

## 启动和停止

推荐一次启动后端与前端：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start.ps1
```

默认访问地址：

- 前端：`http://127.0.0.1:5173`
- API 文档：`http://127.0.0.1:8000/docs`
- 健康检查：`http://127.0.0.1:8000/api/health`
- 详细健康检查：`http://127.0.0.1:8000/api/health/detail`

停止托管进程：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop.ps1
```

服务日志位于 `.runtime/logs/`，进程身份记录位于 `.runtime/state/`。

使用已有 PATH Node.js 时，可以在两个 PowerShell 窗口分别运行：

```powershell
# 窗口 1：后端
Push-Location .\backend
.\.venv\Scripts\python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000
Pop-Location
```

```powershell
# 窗口 2：前端
Push-Location .\frontend
npm run dev -- --host 127.0.0.1
Pop-Location
```

手工启动的进程不受 `stop.ps1` 管理，应在各自终端中按 `Ctrl+C` 停止。

## 图片识别 API

`POST /api/sign-analyzer/analyze` 接收单张图片；`POST /api/sign-analyzer/batch` 接收多张图片，批量接口也允许 ZIP。两个接口都需要 Bearer Token，并支持表单字段 `mode`：

- `auto`：默认。图片最长边不超过 `512` 像素时使用 GTSRB 整图分类器，否则使用 TT100K 街景检测器。
- `classify`：强制使用 GTSRB 整图分类。
- `detect`：强制使用 TT100K 目标检测。

单图示例：

```powershell
curl.exe -X POST "http://127.0.0.1:8000/api/sign-analyzer/analyze" `
  -H "Authorization: Bearer <TOKEN>" `
  -F "mode=auto" `
  -F "image=@Test\00000.png"
```

批量示例：

```powershell
curl.exe -X POST "http://127.0.0.1:8000/api/sign-analyzer/batch" `
  -H "Authorization: Bearer <TOKEN>" `
  -F "mode=classify" `
  -F "files=@Test\00000.png" `
  -F "files=@Test\00006.png"
```

响应包含 `recognition_mode`、`result_type`、`dataset`、模型设备、类别、置信度和标注图 URL。标签同时提供原始类别名及中文字段 `class_name_cn`/`display_name`；任务历史接口为 `/api/sign-analyzer/tasks` 和 `/api/sign-analyzer/tasks/{task_id}`。

## 视频和摄像头

视频接口异步创建任务：

```powershell
$response = curl.exe -sS -X POST "http://127.0.0.1:8000/api/detection/video" `
  -H "Authorization: Bearer <TOKEN>" `
  -F "video=@samples\traffic.mp4" | ConvertFrom-Json

$taskId = $response.data.task_id
curl.exe -H "Authorization: Bearer <TOKEN>" `
  "http://127.0.0.1:8000/api/detection/video/status/$taskId"
```

摄像头页面为 `http://127.0.0.1:5173/camera`。底层 WebSocket 为 `/api/detection/camera?token=<TOKEN>`，先发送 `config`，再发送 Base64 JPEG `frame`；摄像头的 `mode` 表示计算设备，可选 `auto`、`gpu`、`cpu`。检测结果同样包含中文 `class_name_cn` 和 `display_name`。

## 模型、标签和已测结果

默认 TT100K 检测器是 `models/tt100k-yolo11s-reference42.pt`。它来自仓库所有者提供的 42 类 YOLO11 TT100K 训练工程；公开使用与再分发同时受 Ultralytics AGPL-3.0 和 TT100K CC-BY-NC（非商业）条款约束。该权重在其自带 42 类验证集上的记录为：P `0.74464`、R `0.67341`、mAP50 `0.74842`、mAP50-95 `0.57963`。

推理层把 reference42 类别编号映射到项目统一的 TT100K common-45 编号，并使用 SAHI `512x512` 切片、重叠率 `0.2` 检测小目标。该权重缺少 `ph5`、`w32`、`wo` 三类。真实 GPU API 验证中，`97549.jpg` 从整图推理误判的 `pl60` 修正为与官方标注一致的 `pl40`，置信度 `89.32%`，推理耗时约 `343 ms`。

默认 GTSRB 分类器在完整官方 Test 集上的 top-1 为 `95.6611%`，macro recall 为 `90.5966%`，43 类中没有零召回类别；`00000.png` 识别为 class 16，`00006.png` 识别为 class 18。

旧 common-45 模型在 corrected val 上的基线为：P `0.234120`、R `0.310147`、mAP50 `0.177540`、mAP50-95 `0.114286`。

## GTSRB 数据、训练与评估

`Test/` 的 12,630 张图片和 `Test/GT-final_test.csv` 是只读的官方测试集。禁止把 Test 图片或标签复制、硬链接或以其他方式混入 train/val；否则完整 Test 指标会发生数据泄漏，不能作为泛化结果报告。

```powershell
# 验证并准备仓库根目录的 Train.tar，按物理标志轨迹分组切分
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare-gtsrb.ps1

# GPU 训练
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\train-gtsrb-gpu.ps1

# 全量官方 Test 评估
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\evaluate-gtsrb.ps1
```

## TT100K 数据、训练与评估

修正版数据集位于 `training/datasets/tt100k_corrected_45`。固定使用 `train -> train`、`other -> val`、`test -> test` 和既定 45 类顺序；不要把 test 混入训练或验证，也不要把 reference42 自带验证集指标当作 corrected-val 指标。

```powershell
# 仅校验数据与参数
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\train-tt100k-gpu.ps1 -DryRun

# 1280 分辨率 GPU 训练；已验证的 8 GB 显存配置为 batch=8、SGD、lr0=0.01
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\train-tt100k-gpu.ps1

# 在另一个窗口查看 epoch、指标和 GPU 状态
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\watch-tt100k-progress.ps1

# 在 corrected val 上评估指定权重
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\evaluate-tt100k.ps1 `
  -Model "training\runs\tt100k_yolo11n_gpu_corrected_sgd_b8\weights\best.pt" `
  -RunName "tt100k_baseline_corrected"

# 对已完成评估的新模型执行非回退和相对提升 10% 的晋升门槛
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-tt100k-promotion.ps1 `
  -Candidate "training\runs\tt100k_candidate_eval\metrics.json"
```

## 测试和构建

使用引导脚本管理的运行时：

```powershell
Push-Location .\backend
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -m pip check
Pop-Location

.\.runtime\node\npm.cmd --prefix .\frontend run test:run
.\.runtime\node\npm.cmd --prefix .\frontend run build
```

只使用 PATH Node.js 的开发环境，把最后两条命令中的 `.\.runtime\node\npm.cmd` 替换为 `npm`。

## 当前限制

本地模式不提供 PostgreSQL/pgvector、Redis 队列或 MinIO。当前只实现交通标志检测与分类，信号灯检测尚未实现，因此 API 中的 `traffic_lights` 始终为空数组。
