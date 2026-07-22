# Training Workspace

本目录保存本地训练数据和模型产物，不提交大文件。

- `raw/tt100k`: TT100K 原始数据。
- `datasets/tt100k_corrected_45`: 官方切分的 45 类 YOLO 检测数据。
- `raw/gtsrb_final/train_png`: `Train.tar` 解压后的 39,209 张 GTSRB 训练图。
- `datasets/gtsrb_cls_final`: 按轨迹分组的 GTSRB train/val 数据。
- `runs/gtsrb_yolo11n_cls_gpu_final`: GTSRB 分类权重与 Test 指标。
- `runs/tt100k_yolo11n_gpu_corrected_sgd_b8`: corrected TT100K 显式 SGD 检测训练输出。

常用命令：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-gtsrb.ps1
powershell -ExecutionPolicy Bypass -File scripts\train-gtsrb-gpu.ps1
powershell -ExecutionPolicy Bypass -File scripts\evaluate-gtsrb.ps1
powershell -ExecutionPolicy Bypass -File scripts\train-tt100k-gpu.ps1
powershell -ExecutionPolicy Bypass -File scripts\watch-tt100k-progress.ps1
powershell -ExecutionPolicy Bypass -File scripts\check-tt100k-promotion.ps1 `
  -Candidate "training\runs\tt100k_candidate_eval\metrics.json"
```

`Test/` 只用于最终评估，禁止进入训练或验证数据。
