"""Canonical TT100K class IDs used by the local detector API."""

from collections.abc import Mapping, Sequence


TT100K_COMMON_45_CLASSES = (
    "i2",
    "i4",
    "i5",
    "il100",
    "il60",
    "il80",
    "io",
    "ip",
    "p10",
    "p11",
    "p12",
    "p19",
    "p23",
    "p26",
    "p27",
    "p3",
    "p5",
    "p6",
    "pg",
    "ph4",
    "ph4.5",
    "ph5",
    "pl100",
    "pl120",
    "pl20",
    "pl30",
    "pl40",
    "pl5",
    "pl50",
    "pl60",
    "pl70",
    "pl80",
    "pm20",
    "pm30",
    "pm55",
    "pn",
    "pne",
    "po",
    "pr40",
    "w13",
    "w32",
    "w55",
    "w57",
    "w59",
    "wo",
)

TT100K_COMMON_45_LABELS_ZH = (
    "非机动车行驶",
    "机动车行驶",
    "靠右侧道路行驶",
    "最低限速 100 km/h",
    "最低限速 60 km/h",
    "最低限速 80 km/h",
    "其他指示标志",
    "人行横道",
    "禁止小型客车驶入",
    "禁止鸣喇叭",
    "禁止摩托车驶入",
    "禁止向右转弯",
    "禁止向左转弯",
    "禁止载货汽车驶入",
    "禁止运输危险物品车辆驶入",
    "禁止大型客车驶入",
    "禁止掉头",
    "禁止非机动车进入",
    "减速让行",
    "限制高度 4 m",
    "限制高度 4.5 m",
    "限制高度 5 m",
    "最高限速 100 km/h",
    "最高限速 120 km/h",
    "最高限速 20 km/h",
    "最高限速 30 km/h",
    "最高限速 40 km/h",
    "最高限速 5 km/h",
    "最高限速 50 km/h",
    "最高限速 60 km/h",
    "最高限速 70 km/h",
    "最高限速 80 km/h",
    "限制质量 20 t",
    "限制质量 30 t",
    "限制质量 55 t",
    "禁止停放车辆",
    "禁止驶入",
    "其他禁令标志",
    "解除最高限速 40 km/h",
    "十字交叉路口",
    "道路施工",
    "注意儿童",
    "注意行人",
    "右侧合流",
    "其他警告标志",
)

TT100K_LABELS_ZH_BY_CODE = dict(
    zip(TT100K_COMMON_45_CLASSES, TT100K_COMMON_45_LABELS_ZH, strict=True)
)

TT100K_CLASS_ALIASES = {
    "i160": "il60",
    "p\u00f3": "p6",
    "pL80": "pl80",
}


def tt100k_label_zh(class_name: str) -> str | None:
    normalized_name = class_name.strip()
    normalized_name = TT100K_CLASS_ALIASES.get(normalized_name, normalized_name)
    return TT100K_LABELS_ZH_BY_CODE.get(normalized_name)


def _ordered_names(names: Mapping[int, str] | Sequence[str]) -> list[tuple[int, str]]:
    if isinstance(names, Mapping):
        return sorted((int(class_id), str(name)) for class_id, name in names.items())
    return [(class_id, str(name)) for class_id, name in enumerate(names)]


def build_tt100k_class_id_map(
    names: Mapping[int, str] | Sequence[str],
) -> dict[int, int]:
    canonical_ids = {
        name: class_id for class_id, name in enumerate(TT100K_COMMON_45_CLASSES)
    }
    mapping = {}
    used_ids = set()
    for native_id, raw_name in _ordered_names(names):
        normalized_name = TT100K_CLASS_ALIASES.get(raw_name.strip(), raw_name.strip())
        if normalized_name not in canonical_ids:
            raise ValueError(f"Unknown TT100K class name: {raw_name}")
        canonical_id = canonical_ids[normalized_name]
        if canonical_id in used_ids:
            raise ValueError(f"Duplicate TT100K class name: {normalized_name}")
        mapping[native_id] = canonical_id
        used_ids.add(canonical_id)
    return mapping
