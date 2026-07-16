"""Enforce the TT100K checkpoint promotion gate."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


RECALL_KEY = "metrics/recall(B)"
MAP5095_KEY = "metrics/mAP50-95(B)"
GATE_KEYS = (RECALL_KEY, MAP5095_KEY)


def _metric(metrics: dict, key: str) -> float:
    try:
        return float(metrics[key])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"Missing or invalid metric: {key}") from exc


def compare_metrics(
    baseline: dict,
    candidate: dict,
    minimum_relative_improvement: float = 0.10,
) -> dict:
    if minimum_relative_improvement < 0:
        raise ValueError("minimum_relative_improvement must be non-negative")

    baseline_values = {key: _metric(baseline, key) for key in GATE_KEYS}
    candidate_values = {key: _metric(candidate, key) for key in GATE_KEYS}
    non_regression = all(
        candidate_values[key] >= baseline_values[key] for key in GATE_KEYS
    )

    relative_improvements = {}
    for key in GATE_KEYS:
        baseline_value = baseline_values[key]
        candidate_value = candidate_values[key]
        relative_improvements[key] = (
            None
            if baseline_value == 0
            else (candidate_value - baseline_value) / baseline_value
        )

    relative_improvement_met = any(
        (
            candidate_values[key] > 0
            if baseline_values[key] == 0
            else candidate_values[key]
            >= baseline_values[key] * (1 + minimum_relative_improvement)
        )
        for key in GATE_KEYS
    )
    return {
        "passed": non_regression and relative_improvement_met,
        "non_regression": non_regression,
        "relative_improvement_met": relative_improvement_met,
        "minimum_relative_improvement": minimum_relative_improvement,
        "baseline": baseline_values,
        "candidate": candidate_values,
        "relative_improvements": relative_improvements,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--minimum-relative-improvement", type=float, default=0.10)
    return parser


def _load_metrics(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(f"Metrics file not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        report = compare_metrics(
            _load_metrics(args.baseline),
            _load_metrics(args.candidate),
            minimum_relative_improvement=args.minimum_relative_improvement,
        )
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as exc:
        parser.exit(2, f"error: {exc}\n")

    rendered = json.dumps(report, indent=2)
    print(rendered)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
