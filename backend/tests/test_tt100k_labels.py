from app.services.tt100k_labels import (
    TT100K_COMMON_45_CLASSES,
    TT100K_COMMON_45_LABELS_ZH,
    build_tt100k_class_id_map,
    tt100k_label_zh,
)


REFERENCE_42_CATALOG = (
    ("i2", "i2", "非机动车行驶"),
    ("i4", "i4", "机动车行驶"),
    ("i5", "i5", "靠右侧道路行驶"),
    ("il100", "il100", "最低限速 100 km/h"),
    ("i160", "il60", "最低限速 60 km/h"),
    ("il80", "il80", "最低限速 80 km/h"),
    ("io", "io", "其他指示标志"),
    ("ip", "ip", "人行横道"),
    ("p10", "p10", "禁止小型客车驶入"),
    ("p11", "p11", "禁止鸣喇叭"),
    ("p12", "p12", "禁止摩托车驶入"),
    ("p19", "p19", "禁止向右转弯"),
    ("p23", "p23", "禁止向左转弯"),
    ("p26", "p26", "禁止载货汽车驶入"),
    ("p27", "p27", "禁止运输危险物品车辆驶入"),
    ("p3", "p3", "禁止大型客车驶入"),
    ("p5", "p5", "禁止掉头"),
    ("p\u00f3", "p6", "禁止非机动车进入"),
    ("pg", "pg", "减速让行"),
    ("ph4", "ph4", "限制高度 4 m"),
    ("ph4.5", "ph4.5", "限制高度 4.5 m"),
    ("pl100", "pl100", "最高限速 100 km/h"),
    ("pl120", "pl120", "最高限速 120 km/h"),
    ("pl20", "pl20", "最高限速 20 km/h"),
    ("pl30", "pl30", "最高限速 30 km/h"),
    ("pl40", "pl40", "最高限速 40 km/h"),
    ("pl5", "pl5", "最高限速 5 km/h"),
    ("pl50", "pl50", "最高限速 50 km/h"),
    ("pl60", "pl60", "最高限速 60 km/h"),
    ("pl70", "pl70", "最高限速 70 km/h"),
    ("pL80", "pl80", "最高限速 80 km/h"),
    ("pm20", "pm20", "限制质量 20 t"),
    ("pm30", "pm30", "限制质量 30 t"),
    ("pm55", "pm55", "限制质量 55 t"),
    ("pn", "pn", "禁止停放车辆"),
    ("pne", "pne", "禁止驶入"),
    ("po", "po", "其他禁令标志"),
    ("pr40", "pr40", "解除最高限速 40 km/h"),
    ("w13", "w13", "十字交叉路口"),
    ("w55", "w55", "注意儿童"),
    ("w57", "w57", "注意行人"),
    ("w59", "w59", "右侧合流"),
)


def test_tt100k_common_45_chinese_labels_are_complete():
    assert len(TT100K_COMMON_45_CLASSES) == 45
    assert len(TT100K_COMMON_45_LABELS_ZH) == 45
    assert all(label.strip() for label in TT100K_COMMON_45_LABELS_ZH)


def test_tt100k_label_zh_returns_representative_meanings():
    assert tt100k_label_zh("p10") == "禁止小型客车驶入"
    assert tt100k_label_zh("p23") == "禁止向左转弯"
    assert tt100k_label_zh("pl5") == "最高限速 5 km/h"
    assert tt100k_label_zh("pl60") == "最高限速 60 km/h"
    assert tt100k_label_zh("unknown") is None


def test_tt100k_aggregate_labels_use_expected_chinese_meanings():
    io_index = TT100K_COMMON_45_CLASSES.index("io")
    po_index = TT100K_COMMON_45_CLASSES.index("po")

    assert TT100K_COMMON_45_LABELS_ZH[io_index] == "其他指示标志"
    assert TT100K_COMMON_45_LABELS_ZH[po_index] == "其他禁令标志"
    assert tt100k_label_zh("io") == "其他指示标志"
    assert tt100k_label_zh("po") == "其他禁令标志"


def test_tt100k_label_zh_normalizes_whitespace_and_aliases():
    assert tt100k_label_zh("  pL80  ") == "最高限速 80 km/h"


def test_reference_42_model_order_maps_to_every_calibrated_chinese_label():
    native_names = {
        class_id: native_name
        for class_id, (native_name, _canonical_name, _label) in enumerate(
            REFERENCE_42_CATALOG
        )
    }
    class_id_map = build_tt100k_class_id_map(native_names)

    actual = tuple(
        (
            native_name,
            TT100K_COMMON_45_CLASSES[class_id_map[class_id]],
            tt100k_label_zh(TT100K_COMMON_45_CLASSES[class_id_map[class_id]]),
        )
        for class_id, native_name in native_names.items()
    )

    assert len(actual) == 42
    assert actual == REFERENCE_42_CATALOG
    assert {"ph5", "w32", "wo"}.isdisjoint(
        canonical_name for _native, canonical_name, _label in actual
    )
