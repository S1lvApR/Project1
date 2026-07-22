import pytest

from tools.check_yolo_promotion import compare_metrics


BASELINE = {
    "metrics/precision(B)": 0.23,
    "metrics/recall(B)": 0.31,
    "metrics/mAP50(B)": 0.18,
    "metrics/mAP50-95(B)": 0.11,
}


def test_promotion_passes_with_non_regression_and_ten_percent_gain():
    candidate = {
        **BASELINE,
        "metrics/recall(B)": 0.32,
        "metrics/mAP50-95(B)": 0.122,
    }

    report = compare_metrics(BASELINE, candidate)

    assert report["passed"] is True
    assert report["non_regression"] is True
    assert report["relative_improvement_met"] is True


@pytest.mark.parametrize(
    "candidate",
    [
        {**BASELINE, "metrics/recall(B)": 0.30, "metrics/mAP50-95(B)": 0.13},
        {**BASELINE, "metrics/recall(B)": 0.32, "metrics/mAP50-95(B)": 0.115},
    ],
)
def test_promotion_rejects_regression_or_insufficient_gain(candidate):
    assert compare_metrics(BASELINE, candidate)["passed"] is False


def test_promotion_requires_all_gate_metrics():
    with pytest.raises(ValueError, match="metrics/recall"):
        compare_metrics({}, BASELINE)
