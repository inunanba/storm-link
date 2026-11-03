"""Count executed Python assertion checks, independently of source assertion lines."""
import json
import pathlib
import re
import unittest
counts={'checks':0}
for name in ('assertEqual','assertNotEqual','assertIn','assertFalse','assertRaises'):
    original=getattr(unittest.TestCase,name)
    def wrapped(self,*a,_f=original,**kw):
        counts['checks']+=1
        return _f(self,*a,**kw)
    setattr(unittest.TestCase,name,wrapped)
suite=unittest.defaultTestLoader.discover(str(pathlib.Path(__file__).parent))
r=unittest.TextTestRunner(verbosity=2).run(suite)
ROOT=pathlib.Path(__file__).resolve().parents[1]
src=(ROOT/'src/Storm/NativeTests.cls').read_text()
native_defined=len(re.findall(r'^Method Test\w+\(',src,re.M))
# Native counts come only from a saved Storm.Tests.RunTests() log of a real IRIS run.
log=ROOT/'docs/native-test-run.txt'
m=re.search(r'^All PASSED: methods=(\d+) assertions_passed=(\d+) assertions_failed=0$',
            log.read_text() if log.exists() else '',re.M)
metrics={'python_test_methods':r.testsRun,'executed_assertion_checks':counts['checks'],
         'failures':len(r.failures),'errors':len(r.errors),'native_test_methods_defined':native_defined,
         'native_executed':bool(m),'native_test_methods_passed':int(m.group(1)) if m else 0,
         'native_assertions_passed':int(m.group(2)) if m else 0}
(ROOT/'docs/test-metrics.json').write_text(json.dumps(metrics,sort_keys=True)+'\n')
print(json.dumps(metrics,sort_keys=True))
if not r.wasSuccessful():raise SystemExit(1)
