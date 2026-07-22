# 模型 v1 发布契约

`models-v1` 只发布应用默认运行所需的两个模型。项目训练的 common-45 检测器不属于本版本。

## 资源清单

| 文件 | 用途 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| `tt100k-yolo11s-reference42.pt` | TT100K 42 类默认检测器 | 19231379 | `E8A0E0F1E5A9004C708D7EEE9EDD97E9E9D0A7986023E96C807D0FFCD3D50F88` |
| `gtsrb-yolo11n-cls.pt` | GTSRB 43 类默认分类器 | 3291010 | `323E5BD1B0DC5D1F6FBB4C487FAF2320DA0DF9C21132DD46C0C94FEE7B33B16C` |

## 42 类检测器

`tt100k-yolo11s-reference42.pt` 来自仓库所有者提供并指定发布的 42 类 YOLO11 TT100K 训练工程。记录的验证指标为：P `0.74464`、R `0.67341`、mAP50 `0.74842`、mAP50-95 `0.57963`。

默认图片推理使用 SAHI，切片大小 `512x512`，重叠比例 `0.2`。模型输出映射到应用 common-45 标签时缺少 `ph5`、`w32` 和 `wo`，这三个类别不能可靠检测。

## GTSRB 分类器

`gtsrb-yolo11n-cls.pt` 的记录指标为：top-1 `95.6611%`、宏平均召回率 `90.5966%`、零召回类别数 `0`。测试图片 `00000.png` 和 `00006.png` 分别识别为类别 `16` 和 `18`。

## 许可与用途

- 仓库代码和 Ultralytics 派生组件适用 AGPL-3.0；商业闭源用途需要另行评估 Ultralytics 企业许可。
- TT100K 官方页面将数据集标为 [CC BY-NC](https://cg.cs.tsinghua.edu.cn/traffic-sign/)。42 类检测权重仅用于符合该条款的非商业用途，并保留署名与 CVPR 2016 论文引用。
- GTSRB 分类权重的使用者仍需核对 GTSRB 数据来源条款。
- 详细引用见 [第三方说明](../../THIRD_PARTY_NOTICES.md)。

## 完整性校验

```powershell
$expected = @(
    [pscustomobject]@{
        Name = 'tt100k-yolo11s-reference42.pt'
        Size = 19231379
        SHA256 = 'E8A0E0F1E5A9004C708D7EEE9EDD97E9E9D0A7986023E96C807D0FFCD3D50F88'
    }
    [pscustomobject]@{
        Name = 'gtsrb-yolo11n-cls.pt'
        Size = 3291010
        SHA256 = '323E5BD1B0DC5D1F6FBB4C487FAF2320DA0DF9C21132DD46C0C94FEE7B33B16C'
    }
)

foreach ($asset in $expected) {
    $file = Get-Item -LiteralPath $asset.Name
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($file.Length -ne $asset.Size -or $hash -ne $asset.SHA256) {
        throw "$($asset.Name) 完整性校验失败"
    }
}
```

bootstrap 会按 `scripts/config/bootstrap-manifest.json` 中相同的字节数和 SHA-256 自动校验下载结果。
