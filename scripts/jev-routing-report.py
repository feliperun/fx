#!/usr/bin/env python3
"""Offline replay and failure-taxonomy report for native Jev routing.

Reads recorded routing decisions (jev-routing.json files and/or quality-scope
trace logs) and reports where each decision landed. It never calls the network
and never lowers a threshold: it only measures the recorded distribution and,
when probabilities are present, recomputes the decision at alternative bars so
a classifier or policy change can be screened before spending a live run.

Usage:
  scripts/jev-routing-report.py --root DIR [DIR ...]
  scripts/jev-routing-report.py --root DIR --sweep

Decision reasons are read from the recorded telemetry. Records written before
jev-routing-telemetry-v2 cannot separate a transport rejection from a malformed
response; those are reported as legacy_unclassified_failure and are the exact
records the newer telemetry is meant to replace.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import statistics
import sys
from collections import Counter

TAXONOMY_FAMILIES = [
    "code-generation", "debugging-review", "writing", "editing-rewriting",
    "information-seeking", "how-to-advice", "tutoring", "data-math",
    "planning-ideation", "agentic-tool-use", "creative-media",
    "conversational-other",
]

# Reasons a valid response produced; everything else means no usable answer.
VALID = {"classified", "uncertain"}
LEGACY_UNCLASSIFIED = {"evaluation_failed"}
CLASSIFIER_FAULTS = {
    "policy_rejected", "rate_limited", "server_error",
    "transport_timeout", "transport_error", "malformed_response",
    "evaluator_unavailable", "input_too_large", "candidate_ineligible",
}


def decision_reason(decision: dict) -> str:
    return decision.get("reason") or "unknown"


def load_decision_records(root: str) -> list[dict]:
    """Yields one record per routing decision with file provenance."""
    records = []
    for path in sorted(glob.glob(os.path.join(root, "**", "jev-routing.json"), recursive=True)):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, json.JSONDecodeError):
            continue
        for decision in payload.get("decisions", []):
            records.append({"path": path, "telemetry": payload.get("version"), "decision": decision.get("decision", {})})
    if not records:
        # Fall back to trace logs, which carry the same decision JSON.
        pattern = re.compile(r"event=jev_route .*data=(\{.*\})$")
        for path in sorted(glob.glob(os.path.join(root, "**", "fx-trace.log"), recursive=True)):
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    for line in handle:
                        match = pattern.search(line.rstrip("\n"))
                        if not match:
                            continue
                        try:
                            data = json.loads(match.group(1).replace('\\"', '"')) if '\\"' in match.group(1) else json.loads(match.group(1))
                        except json.JSONDecodeError:
                            continue
                        records.append({"path": path, "telemetry": data.get("telemetry"), "decision": data.get("decision", {})})
            except OSError:
                continue
    return records


def summarize(records: list[dict]) -> dict:
    reasons = Counter()
    models = Counter()
    families = Counter()
    latencies: dict[str, list] = {}
    for record in records:
        decision = record["decision"]
        reason = decision_reason(decision)
        reasons[reason] += 1
        models[decision.get("model", "unknown")] += 1
        if decision.get("family"):
            families[decision["family"]] += 1
        if decision.get("elapsed_ms") is not None:
            latencies.setdefault(reason, []).append(decision["elapsed_ms"])

    total = len(records) or 1
    usable = sum(reasons[r] for r in VALID)
    legacy = sum(reasons[r] for r in LEGACY_UNCLASSIFIED)
    faults = sum(reasons[r] for r in CLASSIFIER_FAULTS)
    return {
        "records": len(records),
        "reasons": dict(reasons.most_common()),
        "models": dict(models.most_common()),
        "families": dict(families.most_common()),
        "usable_response_rate": round(usable / total, 4),
        "legacy_unclassified_failure": legacy,
        "classifier_fault_rate": round(faults / total, 4),
        "elapsed_ms_median": {reason: statistics.median(values) for reason, values in latencies.items()},
    }


def screen_thresholds(records: list[dict], family_bars: list[float], class_bars: list[float]) -> list[dict]:
    """Recompute the routing outcome from recorded probabilities at new bars.

    Only records that carry both probabilities can be screened; records without
    a usable answer are reported as unchanged by any threshold change.
    """
    screenable = [r for r in records if r["decision"].get("family_probability") is not None and r["decision"].get("class_probability") is not None]
    outcomes = []
    for family_bar in family_bars:
        for class_bar in class_bars:
            classified = sum(
                1 for r in screenable
                if r["decision"]["family_probability"] >= family_bar and r["decision"]["class_probability"] >= class_bar
            )
            outcomes.append({
                "family_bar": family_bar,
                "class_bar": class_bar,
                "screenable": len(screenable),
                "classified": classified,
                "classified_rate": round(classified / len(screenable), 4) if screenable else None,
            })
    return outcomes


def screen_policy(records: list[dict]) -> dict:
    """Apply the current v2 policy mapping offline to screenable records.

    Mirrors route()'s classified mapping: routine -> luna only when the recorded
    required-context estimate is at or below the routine gate and no image was
    routed, demanding/debugging-review/data-math -> sol, otherwise kimi.
    Non-screenable records (no probabilities) fall back to kimi, exactly as the
    live router does. This is a decision-replay, not an outcome guarantee.
    """
    routine_gate = 64_000
    chosen = Counter()
    routable = 0
    for record in records:
        d = record["decision"]
        fam, cls = d.get("family"), d.get("task_class")
        fp, cp = d.get("family_probability"), d.get("class_probability")
        req = d.get("required_context_tokens")
        if fp is None or cp is None or fp < 0.6 or cp < 0.75:
            chosen["moonshotai/kimi-k3"] += 1
            continue
        routable += 1
        if cls == "routine" and isinstance(req, (int, float)) and req <= routine_gate:
            chosen["openai/gpt-5.6-luna"] += 1
        elif cls == "demanding" or fam in ("debugging-review", "data-math"):
            chosen["openai/gpt-5.6-sol"] += 1
        else:
            chosen["moonshotai/kimi-k3"] += 1
    return {"routable": routable, "policy_selection": dict(chosen.most_common())}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", action="append", required=True, help="directory containing jev-routing.json or fx-trace.log files")
    parser.add_argument("--sweep", action="store_true", help="recompute decisions at alternative probability bars from recorded values")
    parser.add_argument("--policy", action="store_true", help="replay the current v2 policy mapping offline from recorded decisions")
    parser.add_argument("--json", action="store_true", help="emit the full report as JSON")
    args = parser.parse_args(argv)

    records: list[dict] = []
    for root in args.root:
        records.extend(load_decision_records(root))

    report = summarize(records)
    if args.sweep:
        report["threshold_sweep"] = screen_thresholds(records, [0.5, 0.6, 0.7], [0.5, 0.6, 0.68, 0.75])
    if args.policy:
        report["policy_screen"] = screen_policy(records)

    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    print(f"decisions: {report['records']}")
    print(f"usable response rate: {report['usable_response_rate']:.1%}")
    print(f"classifier fault rate: {report['classifier_fault_rate']:.1%}")
    print("\nreasons:")
    for reason, count in report["reasons"].items():
        share = count / (report["records"] or 1)
        median = report["elapsed_ms_median"].get(reason)
        suffix = f" median={median:.0f}ms" if median is not None else ""
        print(f"  {reason:<24} {count:>5}  {share:>6.1%}{suffix}")
    print("\nmodels:")
    for model, count in report["models"].items():
        print(f"  {model:<24} {count:>5}")
    if report["legacy_unclassified_failure"]:
        print(f"\n{report['legacy_unclassified_failure']} decision(s) predate jev-routing-telemetry-v2 and cannot separate transport, malformed and rejection causes.")
    if args.sweep:
        print("\nthreshold screening (offline; recorded probabilities only):")
        for row in report["threshold_sweep"]:
            print(f"  family>={row['family_bar']:<4} class>={row['class_bar']:<5} classified={row['classified']}/{row['screenable']} ({row['classified_rate']:.1%})" if row["classified_rate"] is not None else "  no screenable records")
    if args.policy:
        screen = report["policy_screen"]
        print(f"\npolicy replay (current v2; {screen['routable']} routable of {report['records']}):")
        for model, count in screen["policy_selection"].items():
            print(f"  {model:<24} {count:>5}")
        print("  Note: non-routable records fall back to kimi; this replays choices, not outcomes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
