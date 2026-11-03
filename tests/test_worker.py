import copy
import json
import pathlib
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from worker import Engine, Handler, validate_case, validate_answer, fingerprint
import run_bench2 as b
from run_bench import canon, m_graph
ROOT=pathlib.Path(__file__).resolve().parents[1]
DEV=json.loads((ROOT/'bench/cases.json').read_text())
HOLD=json.loads((ROOT/'bench/heldout_cases.json').read_text())
def runtime(c): return {k:copy.deepcopy(c[k]) for k in ('id','alerts')}
def finish(engine,c):
    state=engine.start(runtime(c)); n=0
    while state['status']=='QUESTION':
        q=state['question']; ans=engine.model_answer(state['token'],q['id'])
        state=engine.complete(state['token'],q['id'],ans);n+=1
        if n>64: raise AssertionError('unbounded')
    return state,n

class WorkerTests(unittest.TestCase):
    def test_01_all_recorded_cases_equal_original_engine(self):
        e=Engine()
        for name,cases in [('dev',DEV),('heldout',HOLD)]:
            rec=json.loads((ROOT/f'recordings/ai_v2_{name}.json').read_text())
            for c in cases:
                out,n=finish(e,c)
                self.assertEqual(canon(out['groups']),canon(b.solve(c,False,rec)[0]))
                self.assertEqual(out['status'],'FINAL')
                self.assertEqual(out['mode'],'replay')
    def test_02_exact_partition_all_cases(self):
        e=Engine()
        for c in DEV+HOLD:
            out,n=finish(e,c);ids=[a['id'] for a in c['alerts']]
            self.assertEqual(sorted(ids),sorted(i for g in out['groups'] for i in g['members']))
            for g in out['groups']: self.assertIn(g['root'],g['members'])
    def test_03_metrics_are_recording_reproduction(self):
        e=Engine()
        for cs,expected in [(DEV,14),(HOLD,11)]:
            self.assertEqual(sum(canon(finish(e,c)[0]['groups'])==canon(c['truth']) for c in cs),expected)
    def test_04_clear_cases_never_call_model(self):
        e=Engine()
        for c in DEV+HOLD:
            if not c['ambiguous']:
                out,n=finish(e,c);self.assertEqual(n,0);self.assertEqual(canon(out['groups']),canon(m_graph(c)))
    def test_05_runtime_labels_rejected(self):
        for c in DEV:
            with self.assertRaises(ValueError):validate_case(c)
    def test_06_invalid_runtime_fields(self):
        base=runtime(DEV[0])
        for k,v in [('id','../x'),('id',''),('alerts',[]),('alerts',None),('id',True)]:
            c=copy.deepcopy(base);c[k]=v
            with self.assertRaises(ValueError):validate_case(c)
    def test_07_alert_validation(self):
        for field,value in [('id','../x'),('c','not-configured'),('t',True),('t',-1),('t',90000),('text',''),('text','\n'),('text','x'*1025)]:
            c=runtime(DEV[0]);c['alerts'][0][field]=value
            with self.assertRaises(ValueError):validate_case(c)
    def test_08_duplicate_id_and_time_window(self):
        c=runtime(DEV[0]);c['alerts'][1]['id']=c['alerts'][0]['id']
        with self.assertRaises(ValueError):validate_case(c)
        c=runtime(DEV[0]);c['alerts'][1]['t']=3601
        with self.assertRaises(ValueError):validate_case(c)
    def test_09_answer_schema(self):
        for v in [None,[],{}, {'answer':'maybe','reason':'x'},{'answer':'yes','reason':''},{'answer':'yes','reason':'x','root':'a0'},{'answer':'no','reason':'bad\nreason'}]:
            with self.assertRaises(ValueError):validate_answer(v)
        for a in ('yes','no'):self.assertEqual(validate_answer({'answer':a,'reason':'evidence'})['answer'],a)
    def test_10_idempotent_start_no_new_session(self):
        e=Engine();a=e.start(runtime(DEV[0]));z=e.start(runtime(DEV[0]))
        self.assertEqual(a,z);self.assertEqual(len(e.sessions),1)
    def test_11_storm_conflict(self):
        e=Engine();c=runtime(DEV[0]);e.start(c);c['alerts'][0]['text']='different'
        with self.assertRaises(ValueError):e.start(c)
    def test_12_forged_or_stale_answer(self):
        e=Engine();s=e.start(runtime(DEV[8]));q=s['question'];v={'answer':'yes','reason':'made up'}
        with self.assertRaises(ValueError):e.complete(s['token'],q['id'],v)
        with self.assertRaises(ValueError):e.complete(s['token'],'0'*64,v)
        self.assertEqual(len(e.sessions[s['token']]['answers']),0)
    def test_13_answer_and_provider_replay_once(self):
        e=Engine();s=e.start(runtime(DEV[8]));q=s['question'];v=e.model_answer(s['token'],q['id'])
        self.assertEqual(v,e.model_answer(s['token'],q['id']))
        nxt=e.complete(s['token'],q['id'],v)
        self.assertEqual(nxt,e.complete(s['token'],q['id'],v))
        with self.assertRaises(ValueError):e.complete(s['token'],q['id'],{'answer':'no' if v['answer']=='yes' else 'yes','reason':v['reason']})
    def test_14_missing_recording_does_not_make_up_answer(self):
        e=Engine();c=runtime(DEV[8]);c['alerts'][0]['text']+=' unseen';s=e.start(c)
        self.assertEqual(s['status'],'QUESTION')
        with self.assertRaises(ValueError):e.model_answer(s['token'],s['question']['id'])
        self.assertFalse(e.sessions[s['token']]['generated'])
    def test_15_fixed_destination_live_provider_and_cache(self):
        calls=[]
        class Resp:
            def __enter__(self):return self
            def __exit__(self,*x):pass
            def read(self,n):return b'{"message":{"content":"{\\"answer\\":\\"yes\\",\\"reason\\":\\"observed evidence\\"}"}}'
        def fake(req,timeout):calls.append((req.full_url,json.loads(req.data),timeout));return Resp()
        e=Engine('live',opener=fake);s=e.start(runtime(DEV[8]));q=s['question']
        self.assertEqual(calls,[])
        self.assertEqual(e.model_answer(s['token'],q['id'])['answer'],'yes')
        e.model_answer(s['token'],q['id'])
        self.assertEqual(len(calls),1);self.assertEqual(calls[0][0],'http://host.docker.internal:11434/api/chat')
        self.assertEqual(calls[0][1]['options'],{'temperature':0,'seed':1})
        self.assertEqual(calls[0][2],90)
    def test_16_hash_binds_text_and_order(self):
        c=runtime(DEV[0]);a=fingerprint(c);c['alerts'][0]['text']+='x'
        self.assertNotEqual(a,fingerprint(c))
        self.assertEqual(fingerprint({'a':1,'b':2}),fingerprint({'b':2,'a':1}))
    def test_17_graph_only_does_not_consult_provider(self):
        def fail(*x):raise AssertionError('no AI for clear')
        for c in DEV:
            if not c['ambiguous']:self.assertEqual(canon(b.solve(c,False,{},provider=fail)[0]),canon(m_graph(c)))
    def test_18_http_contract_and_payload_bound(self):
        class H(Handler):pass
        H.engine=Engine();server=ThreadingHTTPServer(('127.0.0.1',0),H)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        base=f'http://127.0.0.1:{server.server_port}'
        def post(path,data):
            req=urllib.request.Request(base+path,data=json.dumps(data).encode(),headers={'Content-Type':'application/json'})
            return json.loads(urllib.request.urlopen(req).read())
        try:
            self.assertEqual(json.loads(urllib.request.urlopen(base+'/health').read())['mode'],'replay')
            s=post('/start',runtime(DEV[8]));q=s['question']
            x=post('/v1/chat/completions',{'model':'storm-private','messages':[{'role':'user','content':f"STORM_TICKET={s['token']}:{q['id']}"}]})
            v=json.loads(x['choices'][0]['message']['content'])
            self.assertIn(v['answer'],('yes','no'));self.assertEqual(x['choices'][0]['finish_reason'],'stop')
            self.assertIn(post('/answer',{'token':s['token'],'question_id':q['id'],'answer':v})['status'],('QUESTION','FINAL'))
            for path,data in [('/missing',{}),('/v1/chat/completions',{'model':'other'}),('/start',{'blob':'x'*131073})]:
                with self.assertRaises(urllib.error.HTTPError):post(path,data)
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__': unittest.main(verbosity=2)
