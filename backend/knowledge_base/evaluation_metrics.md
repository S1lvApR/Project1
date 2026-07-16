# 模型评估指标详解

## 混淆矩阵

混淆矩阵是分类问题的基础评估工具：

|            | 预测为正例 | 预测为负例 |
|------------|-----------|-----------|
| 实际为正例  | TP        | FN        |
| 实际为负例  | FP        | TN        |

- **TP（True Positive）**：正确检测到的目标
- **FP（False Positive）**：误检（把非目标检测为目标）
- **FN（False Negative）**：漏检（未检测到的真实目标）
- **TN（True Negative）**：正确排除的非目标

## Precision（精确率）

Precision = TP / (TP + FP)

含义：在所有检测结果中，有多少是正确的。
- Precision 高 → 误检少，检测结果可信度高
- Precision 低 → 误检多，需要人工复核

## Recall（召回率）

Recall = TP / (TP + FN)

含义：在所有真实目标中，有多少被成功检测到。
- Recall 高 → 漏检少，覆盖面广
- Recall 低 → 漏检多，可能遗漏重要目标

## Precision 和 Recall 的权衡

在目标检测中，Precision 和 Recall 通常此消彼长：
- 降低置信度阈值 → Recall 升高，Precision 降低
- 升高置信度阈值 → Precision 升高，Recall 降低

选择合适的阈值取决于应用场景：
- 安防监控：宁可误报不能漏报 → 偏重 Recall
- 自动驾驶：误报可能导致急刹 → 偏重 Precision

## F1-Score

F1 = 2 × (Precision × Recall) / (Precision + Recall)

F1 是 Precision 和 Recall 的调和平均数，综合衡量模型性能。

## 训练损失函数

YOLO 训练中的主要损失函数：
1. **Box Loss（边界框损失）**：预测框与真实框的位置偏差
2. **Class Loss（分类损失）**：目标类别的预测误差
3. **Objectness Loss（目标性损失）**：判断区域是否包含目标