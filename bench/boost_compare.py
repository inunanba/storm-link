#!/usr/bin/env python3
"""Offline comparison of component/window grouping and the unchanged graph rule.
Existing recordings are explicitly replay, never a new model run."""
import json
from pathlib import Path
from run_bench import canon, m_graph
from run_bench2 import solve

HERE = Path(__file__).resolve().parent
WINDOW_SECONDS = 60

def component_window(case):
    groups = []
    latest = {}
    for a in sorted(case["alerts"], key=lambda a: (a["t"], a["id"])):
        start, group = latest.get(a["c"], (None, None))
        if start is None or a["t"] - start > WINDOW_SECONDS:
            group = {"root": a["id"], "members": []}
            latest[a["c"]] = a["t"], group
            groups.append(group)
        group["members"].append(a["id"])
    return groups

def main():
    for label, filename, recording in (
        ("development", "cases.json", "ai_v2_dev.json"),
        ("existing second set", "heldout_cases.json", "ai_v2_heldout.json"),
        ("new frozen synthetic challenge set", "boost_challenge_cases.json", None),
    ):
        cases = json.loads((HERE / filename).read_text())
        rec = json.loads((HERE.parent / "recordings" / recording).read_text()) if recording else None
        rows = []
        for case in cases:
            truth = canon(case["truth"])
            rows.append((case["id"], canon(component_window(case)) == truth,
                         canon(m_graph(case)) == truth,
                         canon(solve(case, False, rec)[0]) == truth if rec is not None else None))
        print(label)
        print("case | component/60s | graph | graph+AI replay")
        for row in rows:
            print(" | ".join("N/A" if v is None else str(v) for v in row))
        print("totals |", " | ".join(
            f"{sum(row[i] for row in rows)}/{len(rows)}" if rows[0][i] is not None else "N/A"
            for i in range(1, 4)
        ))

if __name__ == "__main__":
    main()
