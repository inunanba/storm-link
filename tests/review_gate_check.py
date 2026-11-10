"""Separate from the 18-test suite: checks the worker's gate-review side channel.
  python3 tests/review_gate_check.py
Every recorded case is run through the worker; only gate-rejected cases may carry 'review',
and the decision fields are identical to the original engine."""
import json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / 'bench'))
from worker import Engine
import run_bench2 as b
from run_bench import canon
with_review, checked = [], 0
for name in ('cases', 'heldout_cases'):
    rec = json.loads((ROOT / f"recordings/ai_v2_{'dev' if name == 'cases' else 'heldout'}.json").read_text())
    for c in json.loads((ROOT / f'bench/{name}.json').read_text()):
        e = Engine(); s = e.start({'id': c['id'], 'alerts': c['alerts']})
        while s['status'] == 'QUESTION':
            q = s['question']; s = e.complete(s['token'], q['id'], e.model_answer(s['token'], q['id']))
        groups, trace = b.solve(c, False, rec)
        assert canon(s['groups']) == canon(groups), c['id']
        rejected = any(t[0] == 'GATE REJECT' for t in trace)
        assert ('review' in s) == rejected, c['id']
        if rejected:
            with_review.append(c['id'])
            for g in s['review']['groups']:
                assert g['checks'] and all(x['ai_answer'] in ('yes', 'no') for x in g['checks']), c['id']
        checked += 1
print(json.dumps({'cases_checked': checked, 'cases_with_review': with_review}))
assert with_review == ['H12'], with_review
