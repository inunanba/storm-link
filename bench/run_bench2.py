#!/usr/bin/env python3
"""v2: the rule decides clear cases alone; the small model is asked only small yes/no questions on rule-flagged ambiguity.
  python3 bench/run_bench2.py [--set dev|heldout|both] [--live]
Replay by default (recordings/ai_v2_<set>.json). --live calls local Ollama and re-records.
Ambiguity detector (deterministic, documented):
  ROOT-CONFLICT  rule root is a symptom-type alert (queue/backlog/delay/inactivity...) while a downstream member reports a
                 hard error, OR the rule root's text names a downstream member's component -> ask "is root only a symptom of X?"
  COINCIDENCE    a hard-error member shares no content token with any other hard-error member of the group -> ask
                 "same cause as root?"
  No flag -> rule result is final; the model is never called."""
import json, re, sys, time, urllib.request, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from run_bench import TOPO, reach, linked, m_graph, canon, m_exact, m_norm
HERE = pathlib.Path(__file__).resolve().parent
MODEL = "llama3.2-3b-ctx16k:latest"
SYMPTOM = re.compile(r"queue|backlog|delay|waiting|paused|inactivity|no messages|slow", re.I)
STOP = set("error failed failure for from the and with message messages http in to on of by not after expected received code required invalid".split())
def toks(t): return {w for w in re.findall(r"[a-z]+", t.lower()) if len(w) >= 3 and w not in STOP}
def path(a, b):
    prev, st = {a: None}, [a]
    while st:
        x = st.pop(0)
        if x == b:
            p = [];
            while x: p.append(x); x = prev[x]
            return p[::-1]
        for y in TOPO.get(x, []):
            if y not in prev: prev[y] = x; st.append(y)
    return None
def flow(a, b): return " -> ".join(path(a, b) or path(b, a) or [a, b])

def detect(case, grp):
    am = {a["id"]: a for a in case["alerts"]}; mem = [am[i] for i in grp["members"]]; r = am[grp["root"]]
    qs = []
    hard = [a for a in mem if not SYMPTOM.search(a["text"])]
    down_hard = [a for a in hard if a["c"] != r["c"] and reach(r["c"], a["c"])]
    names_down = [a for a in mem if a["c"] != r["c"] and reach(r["c"], a["c"]) and a["c"].lower() in r["text"].lower()]
    if SYMPTOM.search(r["text"]) or names_down:
        for x in (names_down or down_hard): qs.append(("ROOT", x["id"]))
    for a in hard:
        if a["id"] == r["id"] or (a["c"] == r["c"]): continue
        if not any(toks(a["text"]) & toks(b["text"]) for b in hard if b["id"] != a["id"]): qs.append(("COINC", a["id"]))
    return qs

FEW = ("Example 1: Upstream alert on Billing.Router says 'Queue size 900 exceeds threshold'. Downstream alert on Billing.Out.Bank says "
       "'Connection refused by bank gateway'. Path: Billing.Router -> Billing.Out.Bank. When the downstream component fails, messages pile up upstream. Did the downstream failure cause the upstream alert? Answer: yes.\n"
       "Example 2: Root alert on Pharmacy.In says 'Parse error in RXO segment'. Other alert on Pharmacy.Out.Disp says 'Disk usage 95% on /var/log'. "
       "Path: Pharmacy.In -> Pharmacy.Router -> Pharmacy.Out.Disp. Is the other alert caused by the same problem as the root? Answer: no.\n"
       "Example 3: Root alert on Orders.In says 'Order XML missing element PatientId'. Other alert on Orders.Out.LIS says 'LIS rejected order: patient identifier absent'. "
       "Path: Orders.In -> Orders.Out.LIS. Is the other alert caused by the same problem as the root? Answer: yes.\n")
def question(case, kind, rid, xid):
    am = {a["id"]: a for a in case["alerts"]}; r, x = am[rid], am[xid]
    if kind == "ROOT":
        q = (f"Upstream alert on {r['c']} at second {r['t']} says '{r['text']}'. Downstream alert on {x['c']} at second {x['t']} says '{x['text']}'. "
             f"Path: {flow(r['c'], x['c'])}. When the downstream component fails, messages pile up upstream. Did the downstream failure cause the upstream alert?")
    else:
        q = (f"Root alert on {r['c']} at second {r['t']} says '{r['text']}'. Other alert on {x['c']} at second {x['t']} says '{x['text']}'. "
             f"Path: {flow(r['c'], x['c'])}. Is the other alert caused by the same problem as the root?")
    return q

def ask(case, kind, rid, xid):
    q = question(case, kind, rid, xid)
    schema = {"type": "object", "properties": {"answer": {"type": "string", "enum": ["yes", "no"]}, "reason": {"type": "string"}}, "required": ["answer", "reason"]}
    body = {"model": MODEL, "stream": False, "format": schema, "options": {"temperature": 0, "seed": 1},
            "messages": [{"role": "system", "content": "You are an on-call integration engineer. Answer one yes/no question in JSON with a one-sentence reason."},
                         {"role": "user", "content": FEW + "\nNow the real question. " + q}]}
    t0 = time.time()
    r_ = json.loads(urllib.request.urlopen(urllib.request.Request("http://localhost:11434/api/chat", data=json.dumps(body).encode()), timeout=600).read())
    d = json.loads(r_["message"]["content"]); d.update(question=q, model=MODEL, latency_s=round(time.time() - t0, 1))
    return d

def solve(case, live, rec, use_ai=True, provider=None):
    out, trace = [], []
    am = {a["id"]: a for a in case["alerts"]}
    for grp in m_graph(case):
        qs = detect(case, grp) if len(grp["members"]) > 1 else []
        if not qs or not use_ai: out.append(grp); continue
        root, detach = grp["root"], []
        for kind, xid in [q for q in qs if q[0] == "ROOT"] + [q for q in qs if q[0] == "COINC"]:
            rid = root if kind == "COINC" else grp["root"]
            key = f"{case['id']}:{kind}:{rid}:{xid}"
            if provider is not None:
                d = provider(case, kind, rid, xid, key)
            else:
                if live: rec[key] = ask(case, kind, rid, xid)
                d = rec.get(key)
            ans = (d or {}).get("answer")
            trace.append((key, ans, (d or {}).get("reason")))
            if kind == "ROOT" and ans == "yes" and root == grp["root"]: root = xid
            if kind == "COINC" and ans == "no" and xid != root: detach.append(xid)
        # gate: detach <= half, kept members topology-linked to root
        keep = [i for i in grp["members"] if i not in detach]
        if len(detach) * 2 > len(grp["members"]) or not all(linked(am[i]["c"], am[root]["c"]) for i in keep):
            trace.append(("GATE REJECT", case["id"])); out.append(grp); continue
        out.append({"root": root, "members": keep}); out += [{"root": s, "members": [s]} for s in detach]
    return out, trace

def run(name, live):
    cases = json.load(open(HERE / ("cases.json" if name == "dev" else "heldout_cases.json")))
    recf = HERE.parent / "recordings" / f"ai_v2_{name}.json"
    rec = {} if live else (json.load(open(recf)) if recf.exists() else {})
    rows = {"1 exact-match simulation": {}, "2 normalized text": {}, "3 graph rule": {}, "5 rule + detector + 3B yes/no (gated)": {}}; flagged = []; traces = {}
    for c in cases:
        rows["1 exact-match simulation"][c["id"]] = canon(m_exact(c)) == canon(c["truth"])
        rows["2 normalized text"][c["id"]] = canon(m_norm(c)) == canon(c["truth"])
        rows["3 graph rule"][c["id"]] = canon(m_graph(c)) == canon(c["truth"])
        g, tr = solve(c, live, rec); traces[c["id"]] = tr
        if tr: flagged.append(c["id"])
        rows["5 rule + detector + 3B yes/no (gated)"][c["id"]] = canon(g) == canon(c["truth"])
    if live: json.dump(rec, open(recf, "w"), indent=1, ensure_ascii=False)
    amb = [c["id"] for c in cases if c["ambiguous"]]; clr = [c["id"] for c in cases if not c["ambiguous"]]
    print(f"\n## {name} set ({'LIVE' if live else 'REPLAY'}) cases={len(cases)} clear={len(clr)} ambiguous={len(amb)}  AI-flagged: {', '.join(flagged) or '-'}")
    print("| method | all | clear | ambiguous | " + " | ".join(c["id"] for c in cases) + " |")
    print("|---|---|---|---|" + "---|" * len(cases))
    for n, r in rows.items():
        s = lambda ids: f"{sum(r[i] for i in ids)}/{len(ids)}" if ids else "-"
        print(f"| {n} | {s(list(r))} | {s(clr)} | {s(amb)} | " + " | ".join("✓" if r[c['id']] else "✗" for c in cases) + " |")
    wins = [i for i in amb if rows["5 rule + detector + 3B yes/no (gated)"][i] and not rows["3 graph rule"][i]]
    loss = [i for i in cases_ids(cases) if rows["3 graph rule"][i] and not rows["5 rule + detector + 3B yes/no (gated)"][i]]
    print(f"AI wins over rule: {wins or '-'}   AI losses vs rule: {loss or '-'}")
    for cid, tr in traces.items():
        for t in tr: print("  ", t)
def cases_ids(cs): return [c["id"] for c in cs]
if __name__ == "__main__":
    s = sys.argv[sys.argv.index("--set") + 1] if "--set" in sys.argv else "both"
    for n in (["dev", "heldout"] if s == "both" else [s]): run(n, "--live" in sys.argv)
