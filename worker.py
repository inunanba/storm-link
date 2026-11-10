"""Private synthetic-demo worker. IRIS owns the durable receipt and native writes.

The worker supplies deterministic questions; %AI.Agent invokes its OpenAI-compatible
provider route; only that generated answer can advance the matching question.
No live call is made by /start or /answer. No labels enter runtime inference.
"""
import hashlib
import json
import os
import pathlib
import re
import secrets
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'bench'))
import run_bench2 as bench

MAX_BYTES = 131072
MAX_QUESTIONS = 64
# Operator-set at deploy time only (never from event/model data).
OLLAMA_URL = os.environ.get('STORM_OLLAMA_URL', 'http://host.docker.internal:11434').rstrip('/') + '/api/chat'

def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()

def validate_case(value):
    if not isinstance(value, dict) or set(value) != {'id', 'alerts'}:
        raise ValueError('only id and alerts are runtime inputs')
    if not isinstance(value['id'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', value['id']):
        raise ValueError('invalid storm id')
    alerts = value['alerts']
    if not isinstance(alerts, list) or not 1 <= len(alerts) <= 32:
        raise ValueError('1..32 alerts required')
    seen = set()
    for a in alerts:
        if not isinstance(a, dict) or set(a) != {'id', 'c', 't', 'text'}:
            raise ValueError('invalid alert fields')
        if not isinstance(a['id'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', a['id']) or a['id'] in seen:
            raise ValueError('invalid/duplicate alert id')
        seen.add(a['id'])
        if a['c'] not in bench.TOPO:
            raise ValueError('component absent from versioned topology')
        if type(a['t']) is not int or not 0 <= a['t'] <= 86400:
            raise ValueError('invalid time')
        if not isinstance(a['text'], str) or not 1 <= len(a['text']) <= 1024 or any(ord(c) < 32 for c in a['text']):
            raise ValueError('invalid text')
    # Storm window is explicit; the draft graph itself has no temporal bound.
    if max(a['t'] for a in alerts) - min(a['t'] for a in alerts) > 3600:
        raise ValueError('storm exceeds 3600 second window')
    return json.loads(json.dumps(value))

def validate_answer(value):
    if not isinstance(value, dict) or set(value) != {'answer', 'reason'}:
        raise ValueError('answer and reason only')
    if value['answer'] not in ('yes', 'no') or not isinstance(value['reason'], str) or not 1 <= len(value['reason']) <= 800:
        raise ValueError('invalid answer')
    if any(ord(c) < 32 for c in value['reason']):
        raise ValueError('reason contains control characters')
    return dict(value)

def gate_review(case, trace):
    """Groups whose AI proposal the deterministic gate rejected, with the questions a human should re-check.
    bench.solve appends, per flagged graph group in order, one trace entry per question and then
    ('GATE REJECT', id) if the proposal was discarded. The kept result is the graph-rule group."""
    am = {a['id']: a for a in case['alerts']}
    items, pos = [], 0
    for grp in bench.m_graph(case):
        qs = bench.detect(case, grp) if len(grp['members']) > 1 else []
        if not qs:
            continue
        entries, pos = trace[pos:pos + len(qs)], pos + len(qs)
        if pos < len(trace) and trace[pos][0] == 'GATE REJECT':
            pos += 1
            checks = []
            for key, ans, reason in entries:
                kind, rid, xid = key.rsplit(':', 3)[1:]
                checks.append({'kind': kind, 'root': rid, 'member': xid, 'ai_answer': ans, 'ai_reason': reason,
                               'root_alert': {'c': am[rid]['c'], 'text': am[rid]['text']},
                               'member_alert': {'c': am[xid]['c'], 'text': am[xid]['text']}})
            items.append({'kept_root': grp['root'], 'kept_members': list(grp['members']), 'checks': checks})
    return {'reason': 'ai_proposal_rejected_by_gate', 'groups': items} if items else None

class Pending(Exception):
    def __init__(self, question):
        self.question = question

class Engine:
    def __init__(self, mode='replay', model='llama3.2-3b-ctx16k:latest', opener=None):
        if mode not in ('replay', 'live'):
            raise ValueError('mode must be replay or live')
        self.mode, self.model = mode, model
        self.opener = opener or urllib.request.urlopen
        self.sessions = {}
        self.by_id = {}
        self.lock = threading.RLock()
        self.recordings = {}
        for name in ('dev', 'heldout'):
            for entry in json.loads((ROOT / 'recordings' / f'ai_v2_{name}.json').read_text()).values():
                q = entry.get('question')
                if q:
                    if q in self.recordings and self.recordings[q]['answer'] != entry['answer']:
                        raise ValueError('conflicting recording')
                    self.recordings[q] = entry

    def start(self, case):
        case = validate_case(case)
        digest = fingerprint(case)
        with self.lock:
            if case['id'] in self.by_id:
                token = self.by_id[case['id']]
                if self.sessions[token]['digest'] != digest:
                    raise ValueError('storm id conflict')
                return self.advance(token)
            if len(self.sessions) >= 256:
                raise ValueError('worker session capacity; restart only after IRIS reconciliation')
            token = secrets.token_hex(16)
            self.by_id[case['id']] = token
            self.sessions[token] = {'case': case, 'digest': digest, 'answers': {}, 'generated': {}, 'pending': None}
            return self.advance(token)

    def advance(self, token):
        s = self.sessions[token]
        def provider(case, kind, rid, xid, key):
            q = bench.question(case, kind, rid, xid)
            qid = fingerprint({'storm': s['digest'], 'key': key, 'question': q})
            if qid not in s['answers']:
                raise Pending({'id': qid, 'text': q, 'kind': kind, 'root': rid, 'member': xid})
            return s['answers'][qid]
        try:
            groups, trace = bench.solve(s['case'], False, {}, provider=provider)
            # Exact partition and candidate membership are checked after the model.
            ids = [a['id'] for a in s['case']['alerts']]
            flat = [i for g in groups for i in g['members']]
            if sorted(ids) != sorted(flat) or any(g['root'] not in g['members'] for g in groups):
                raise ValueError('partition gate failed')
            s['pending'] = None
            out = {'token': token, 'status': 'FINAL', 'mode': self.mode, 'groups': groups,
                   'answers': s['answers'], 'topology_hash': fingerprint(bench.TOPO), 'input_hash': s['digest']}
            review = gate_review(s['case'], trace)
            if review:
                # Side channel for IRIS only: Storm.Process removes it before the receipt is saved.
                out['review'] = review
            return out
        except Pending as p:
            if len(s['answers']) >= MAX_QUESTIONS:
                raise ValueError('question bound exceeded')
            s['pending'] = p.question
            return {'token': token, 'status': 'QUESTION', 'mode': self.mode, 'question': p.question}

    def complete(self, token, qid, value):
        value = validate_answer(value)
        with self.lock:
            s = self.sessions[token]
            if qid in s['answers']:
                if value != s['answers'][qid]:
                    raise ValueError('answer replay conflict')
                return self.advance(token)
            if not s['pending'] or s['pending']['id'] != qid:
                raise ValueError('question not pending')
            if s['generated'].get(qid) != value:
                raise ValueError('answer must match the provider response for this question')
            s['answers'][qid] = value
            return self.advance(token)

    def model_answer(self, token, qid):
        with self.lock:
            s = self.sessions[token]
            if qid in s['generated']:
                return s['generated'][qid]
            p = s['pending']
            if not p or p['id'] != qid:
                raise ValueError('question not pending')
            q = p['text']
            if self.mode == 'replay':
                if q not in self.recordings:
                    raise ValueError('no exact recording; no invented model response')
                entry = self.recordings[q]
                value = {'answer': entry['answer'], 'reason': entry['reason']}
                s.setdefault('meta', {})[qid] = {'model': entry.get('model', self.model) + ' (recorded)'}
            else:
                body = {'model': self.model, 'stream': False,
                        'format': {'type': 'object', 'properties': {'answer': {'type': 'string', 'enum': ['yes', 'no']},
                                   'reason': {'type': 'string'}}, 'required': ['answer', 'reason'], 'additionalProperties': False},
                        'options': {'temperature': 0, 'seed': 1},
                        'messages': [{'role': 'system', 'content': 'You are an on-call integration engineer. Answer one yes/no question in JSON with a one-sentence reason.'},
                                     {'role': 'user', 'content': bench.FEW + '\nNow the real question. ' + q}]}
                # Fixed service destination, never supplied by event/model data.
                req = urllib.request.Request(OLLAMA_URL,
                                             data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
                with self.opener(req, timeout=90) as response:
                    raw = response.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES:
                    raise ValueError('model response size exceeded')
                reply = json.loads(raw)
                value = json.loads(reply['message']['content'])
                meta = {'model': self.model + ' (live)'}
                if isinstance(reply.get('prompt_eval_count'), int) and isinstance(reply.get('eval_count'), int):
                    meta['usage'] = {'prompt_tokens': reply['prompt_eval_count'], 'completion_tokens': reply['eval_count'],
                                     'total_tokens': reply['prompt_eval_count'] + reply['eval_count']}
                s.setdefault('meta', {})[qid] = meta
            s['generated'][qid] = validate_answer(value)
            return s['generated'][qid]

    def answer_meta(self, token, qid):
        with self.lock:
            s = self.sessions.get(token) or {}
            return dict(s.get('meta', {}).get(qid, {}))

class Handler(BaseHTTPRequestHandler):
    engine = None
    def log_message(self, *args):
        pass  # no event text, ticket or raw provider data in access logs
    def send(self, status, obj):
        raw = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def do_GET(self):
        if self.path == '/health':
            self.send(200, {'status': 'ok', 'mode': self.engine.mode, 'topology_hash': fingerprint(bench.TOPO)})
        else:
            self.send(404, {'status': 'UNKNOWN'})
    def do_POST(self):
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 1 <= size <= MAX_BYTES:
                raise ValueError('request size')
            data = json.loads(self.rfile.read(size))
            if self.path == '/start':
                out = self.engine.start(data)
            elif self.path == '/answer':
                if set(data) != {'token', 'question_id', 'answer'}:
                    raise ValueError('answer fields')
                out = self.engine.complete(data['token'], data['question_id'], data['answer'])
            elif self.path == '/v1/chat/completions':
                if data.get('stream') or data.get('model') != 'storm-private':
                    raise ValueError('unsupported provider mode')
                text = '\n'.join(m.get('content', '') for m in data['messages'] if m.get('role') == 'user')
                matches = re.findall(r'STORM_TICKET=([a-f0-9]{32}):([a-f0-9]{64})', text)
                if len(matches) != 1:
                    raise ValueError('one issued ticket required')
                value = self.engine.model_answer(*matches[0])
                meta = self.engine.answer_meta(*matches[0])
                out = {'id': 'storm-answer', 'object': 'chat.completion', 'created': int(time.time()),
                       'model': meta.get('model', 'storm-private'), 'choices': [{'index': 0, 'finish_reason': 'stop',
                       'message': {'role': 'assistant', 'content': json.dumps(value)}}]}
                if 'usage' in meta:
                    out['usage'] = meta['usage']  # only real counts from a live call; never invented
            else:
                self.send(404, {'status': 'UNKNOWN'})
                return
            self.send(200, out)
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.send(422, {'status': 'UNKNOWN', 'reason': 'request or recording validation failed'})
        except Exception:
            self.send(503, {'status': 'UNKNOWN', 'reason': 'provider unavailable; reconcile original storm'})

if __name__ == '__main__':
    Handler.engine = Engine(os.environ.get('STORM_MODE', 'replay'), os.environ.get('STORM_MODEL', 'llama3.2-3b-ctx16k:latest'))
    ThreadingHTTPServer(('0.0.0.0', 8088), Handler).serve_forever()
