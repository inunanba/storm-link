Include %occStatus
Class Storm.Worker Extends %RegisteredObject
{
ClassMethod Call(path As %String, body As %String) As %DynamicObject
{
  If (path'="/start")&&(path'="/answer") { Throw ##class(%Exception.General).%New("worker route rejected") }
  Set http=##class(%Net.HttpRequest).%New()
  Set http.Server=$Get(^Storm.Config("worker.host"),"worker"),http.Port=8088,http.Timeout=100,http.ContentType="application/json"
  Do http.EntityBody.Write(body)
  Set sc=http.Post(path)
  If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("worker transport unavailable") }
  If http.HttpResponse.StatusCode'=200 { Throw ##class(%Exception.General).%New("worker did not return a validated result") }
  Set raw=http.HttpResponse.Data.Read(32767)
  Quit ##class(%DynamicObject).%FromJSON(raw)
}
}
