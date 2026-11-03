Include %occStatus
Class Storm.NativeTests Extends %UnitTest.TestCase
{
Method CheckCase(cid As %String)
{
  Set stream=##class(%Stream.FileCharacter).%New()
  Set sc=stream.LinkToFile("/opt/storm/fixtures/"_cid_".json")
  Do $$$AssertEquals(sc,1,"fixture available")
  Set payload=stream.Read(32767),sc=##class(Storm.Service).Submit(cid,payload,.out)
  Do $$$AssertEquals(sc,1,"service status")
  Do $$$AssertEquals(out.Status,"FINAL","workflow final")
  Do $$$AssertEquals(##class(Storm.Process).Reconcile(cid),"FINAL","durable final receipt")
  Set before=^Storm.Receipt(cid,"result"),sc=##class(Storm.Service).Submit(cid,payload,.again)
  Do $$$AssertEquals(again.Payload,before,"same ID returns exact saved receipt")
  Do $$$AssertEquals(again.Status,"FINAL","same ID does not rerun workflow")
}
Method TestC01() { Do ..CheckCase("C01") }
Method TestC02() { Do ..CheckCase("C02") }
Method TestC03() { Do ..CheckCase("C03") }
Method TestC04() { Do ..CheckCase("C04") }
Method TestC05() { Do ..CheckCase("C05") }
Method TestC06() { Do ..CheckCase("C06") }
Method TestC07() { Do ..CheckCase("C07") }
Method TestC08() { Do ..CheckCase("C08") }
Method TestA1() { Do ..CheckCase("A1") }
Method TestA2() { Do ..CheckCase("A2") }
Method TestA3() { Do ..CheckCase("A3") }
Method TestA4() { Do ..CheckCase("A4") }
}
