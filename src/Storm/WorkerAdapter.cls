Include %occStatus
/// Custom outbound adapter: HTTP JSON post to the private Storm worker.
Class Storm.WorkerAdapter Extends Ens.OutboundAdapter
{
Parameter SETTINGS = "HTTPServer:Basic,HTTPPort:Basic";
Property HTTPServer As %String [ InitialExpression = "127.0.0.1" ];
Property HTTPPort As %Integer [ InitialExpression = 8088 ];

Method OnInit() As %Status
{
  If $Get(^Storm.Config("worker.host"))'="" Set ..HTTPServer=^Storm.Config("worker.host")
  Quit $$$OK
}

Method PostJSON(path As %String, body As %String) As %DynamicObject
{
  If (path'="/start")&&(path'="/answer") { Throw ##class(%Exception.General).%New("worker route rejected") }
  Set http=##class(%Net.HttpRequest).%New()
  Set http.Server=..HTTPServer,http.Port=..HTTPPort,http.Timeout=100,http.ContentType="application/json"
  Do http.EntityBody.Write(body)
  Set sc=http.Post(path)
  If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("worker transport unavailable") }
  If http.HttpResponse.StatusCode'=200 { Throw ##class(%Exception.General).%New("worker did not return a validated result") }
  Set raw=http.HttpResponse.Data.Read(32767)
  Quit ##class(%DynamicObject).%FromJSON(raw)
}
}
