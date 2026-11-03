/// Single entry point for all native tests: Do ##class(Storm.Tests).RunTests()
Class Storm.Tests
{

/// Runs every native %UnitTest case and prints one summary line.
/// Returns 1 when every method and assertion passed.
ClassMethod RunTests(cases As %String = "Storm.NativeTests") As %Boolean
{
  Set ^UnitTestRoot="/tmp/"
  For k=1:1:$Length(cases,",") {
    Do ##class(%UnitTest.Manager).DebugRunTestCase("",$Piece(cases,",",k),"/nodelete/noload","")
  }
  Set run=$Order(^UnitTest.Result(""),-1),(methods,pass,fail,mfail)=0,s=""
  For  { Set s=$Order(^UnitTest.Result(run,s)) Quit:s=""
    Set c="" For  { Set c=$Order(^UnitTest.Result(run,s,c)) Quit:c=""
      Set t="" For  { Set t=$Order(^UnitTest.Result(run,s,c,t)) Quit:t=""
        Set methods=methods+1 Set:$ListGet(^UnitTest.Result(run,s,c,t),1)'=1 mfail=mfail+1
        Set a="" For  { Set a=$Order(^UnitTest.Result(run,s,c,t,a)) Quit:a=""
          Set v=^UnitTest.Result(run,s,c,t,a)
          // Count assertions only; LogMessage entries (durations) are not checks.
          Continue:$Extract($ListGet(v,2),1,6)'="Assert"
          If $ListGet(v,1)=1 { Set pass=pass+1 } Else { Set fail=fail+1 Write "FAIL ",t," ",$ListGet(v,3),! }
        } } } }
  Set ok=(methods>0)&&(fail=0)&&(mfail=0)
  Write !,$Select(ok:"All PASSED",1:"FAILED"),": methods=",methods," assertions_passed=",pass," assertions_failed=",fail,!
  Quit ok
}

}
