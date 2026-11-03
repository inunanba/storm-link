#!/usr/bin/env python3
"""Labelled alert-storm benchmark. One command rebuilds the results table:
  python3 bench/run_bench.py            # methods 1-3 + method 4 from replay (recordings/ai_decisions.json)
  python3 bench/run_bench.py --live     # method 4 calls local Ollama and re-records decisions
Methods: 1 built-in exact (source+text), 2 normalized text, 3 graph rule, 4 graph rule + small LLM choosing among rule candidates + deterministic gate.
A case is correct only if the predicted groups AND each group's root match the ground truth exactly."""
import json, re, sys, time, urllib.request, pathlib
HERE = pathlib.Path(__file__).resolve().parent
TOPO = json.load(open(HERE / "topology.json"))["edges"]
CASES = json.load(open(HERE / "cases.json"))
REC = HERE.parent / "recordings" / "ai_decisions.json"
MODEL = "llama3.2-3b-ctx16k:latest"

def reach(a, b):
    seen, st = set(), [a]
    while st:
        x = st.pop()
        for y in TOPO.get(x, []):
            if y == b: return True
            if y not in seen: seen.add(y); st.append(y)
    return False
def linked(a, b): return a == b or reach(a, b) or reach(b, a)

def by_key(alerts, key):
    g = {}
    for a in sorted(alerts, key=lambda a: a["t"]): g.setdefault(key(a), []).append(a)
    return [{"root": v[0]["id"], "members": [x["id"] for x in v]} for v in g.values()]

def m_exact(case): return by_key(case["alerts"], lambda a: (a["c"], a["text"]))
def norm(t): return re.sub(r"\s+", " ", re.sub(r"'[^']*'|\b[\w.-]*\d[\w.-]*\b", "#", t.lower())).strip()
def m_norm(case): return by_key(case["alerts"], lambda a: norm(a["text"]))

def rule_root(members):
    up = [a for a in members if not any(b["c"] != a["c"] and reach(b["c"], a["c"]) for b in members)]
    return min(up or members, key=lambda a: a["t"])
def m_graph(case):
    groups, left = [], list(case["alerts"])
    while left:
        comp = [left.pop(0)]
        changed = True
        while changed:
            changed = False
            for a in list(left):
                if any(linked(a["c"], b["c"]) for b in comp): comp.append(a); left.remove(a); changed = True
        r = rule_root(comp)
        groups.append({"root": r["id"], "members": [a["id"] for a in sorted(comp, key=lambda a: a["t"])]})
    return groups

SCHEMA_DESC = "root_id must be one of the candidate ids; related_ids lists every other candidate id that IS a consequence of the root. Leave an id out only if it is an unrelated coincidence."
def ask_llm(case, grp):
    amap = {a["id"]: a for a in case["alerts"]}
    mem = [amap[i] for i in grp["members"]]
    ids = [a["id"] for a in mem]
    lines = " ".join(f"Alert {a['id']} came from {a['c']} at second {a['t']} and says: {a['text']}." for a in mem)
    flow = " ".join(f"{a['c']} sends messages to {', '.join(TOPO.get(a['c'], [])) or 'nothing inside the production'}." for a in mem)
    user = (f"These alerts were grouped together by a topology rule. {lines} Message flow: {flow} "
            f"The rule thinks the root is {grp['root']} because it is the most upstream. Remember that a failing downstream "
            f"component can make upstream queues grow, and that an alert can also be an unrelated coincidence. "
            f"Which alert is the real root cause, and which alerts, if any, are unrelated to it? {SCHEMA_DESC}")
    schema = {"type": "object", "properties": {"root_id": {"type": "string", "enum": ids},
              "related_ids": {"type": "array", "items": {"type": "string", "enum": ids}},
              "reason": {"type": "string"}}, "required": ["root_id", "related_ids", "reason"]}
    body = {"model": MODEL, "stream": False, "format": schema, "options": {"temperature": 0, "seed": 1},
            "messages": [{"role": "system", "content": "You are an on-call integration engineer. Answer in JSON."},
                         {"role": "user", "content": user}]}
    t0 = time.time()
    r = json.loads(urllib.request.urlopen(urllib.request.Request("http://localhost:11434/api/chat",
            data=json.dumps(body).encode()), timeout=600).read())
    d = json.loads(r["message"]["content"])
    rel = set(d.get("related_ids") or [])
    d["separate_ids"] = [i for i in ids if i != d.get("root_id") and i not in rel]  # derived; schema asks for the positive list (3B confused the negative one in run1)
    d.update(model=MODEL, latency_s=round(time.time() - t0, 1), eval_tokens=r.get("eval_count"), prompt_tokens=r.get("prompt_eval_count"))
    return d

def gate(case, grp, d):
    """Deterministic gate: final call. Returns (groups, verdict)."""
    amap = {a["id"]: a for a in case["alerts"]}
    mem, root, sep = grp["members"], d.get("root_id"), list(dict.fromkeys(d.get("separate_ids") or []))
    if root not in mem: return [grp], "REJECT root not a candidate"
    if root in sep or any(s not in mem for s in sep): return [grp], "REJECT invalid separate_ids"
    if len(sep) * 2 > len(mem): return [grp], "REJECT detaches more than half"
    keep = [i for i in mem if i not in sep]
    if not all(linked(amap[i]["c"], amap[root]["c"]) for i in keep): return [grp], "REJECT root not topology-linked to members"
    out = [{"root": root, "members": keep}] + [{"root": s, "members": [s]} for s in sep]
    return out, "ACCEPT"

def m_graph_ai(case, live, rec):
    out, trace = [], []
    for grp in m_graph(case):
        if len(grp["members"]) < 2: out.append(grp); continue
        key = f"{case['id']}:{grp['root']}:{','.join(grp['members'])}"
        if live: rec[key] = ask_llm(case, grp)
        d = rec.get(key)
        if d is None: out.append(grp); trace.append((key, "NO RECORDING -> rule")); continue
        g, v = gate(case, grp, d); out += g; trace.append((key, v, d.get("root_id"), d.get("separate_ids"), d.get("reason")))
    return out, trace

def canon(gs): return sorted((g["root"], tuple(sorted(g["members"]))) for g in gs)
def main():
    live = "--live" in sys.argv
    rec = {} if live else (json.load(open(REC)) if REC.exists() else {})
    methods = [("1 built-in exact", m_exact), ("2 normalized text", m_norm), ("3 graph rule", m_graph)]
    res = {n: {} for n, _ in methods}; res["4 graph+AI (3B, gated)"] = {}
    traces = {}
    for c in CASES:
        for n, f in methods: res[n][c["id"]] = canon(f(c)) == canon(c["truth"])
        g, tr = m_graph_ai(c, live, rec); traces[c["id"]] = tr
        res["4 graph+AI (3B, gated)"][c["id"]] = canon(g) == canon(c["truth"])
    if live:
        REC.parent.mkdir(exist_ok=True); json.dump(rec, open(REC, "w"), indent=1, ensure_ascii=False)
    amb = [c["id"] for c in CASES if c["ambiguous"]]; clr = [c["id"] for c in CASES if not c["ambiguous"]]
    print(f"mode: {'LIVE' if live else 'REPLAY'}  cases={len(CASES)} clear={len(clr)} ambiguous={len(amb)}\n")
    print("| method | all | clear | ambiguous | " + " | ".join(c["id"] for c in CASES) + " |")
    print("|---|---|---|---|" + "---|" * len(CASES))
    for n, r in res.items():
        s = lambda ids: f"{sum(r[i] for i in ids)}/{len(ids)}"
        print(f"| {n} | {s(list(r))} | {s(clr)} | {s(amb)} | " + " | ".join("✓" if r[c['id']] else "✗" for c in CASES) + " |")
    print("\nAI trace (gate verdicts):")
    for cid, tr in traces.items():
        for t in tr: print(" ", cid, t)
if __name__ == "__main__": main()
