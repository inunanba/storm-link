Include %occStatus

/// Dedicated business process. No shared pool with Storm.Process.
Class Storm.PexDispatch Extends Ens.BusinessProcess
{
Method OnRequest(request As %Library.Persistent, Output response As %Library.Persistent) As %Status
{
  If $IsObject(request) {
    If request.%IsA("Storm.PexRequest") Do ##class(Storm.PexSidecar).Dispatch($THIS,request)
  }
  Quit $$$OK
}

Method OnResponse(request As %Library.Persistent, ByRef response As %Library.Persistent, callrequest As %Library.Persistent, callresponse As %Library.Persistent, pCompletionKey As %String) As %Status
{
  If pCompletionKey="StormJavaHandoff",$IsObject(callresponse) {
    // A generic transport error or an empty reply isn't a drain acknowledgement.
    Quit:'callresponse.%IsA("Storm.PexReply") $$$OK
    Do ##class(Storm.PexSidecar).Finish(request.StormId,callresponse)
  }
  Quit $$$OK
}

Method OnError(request As %Library.Persistent, ByRef response As %Library.Persistent, callrequest As %Library.Persistent, pErrorStatus As %Status, pCompletionKey As %String) As %Status
{
  // A transport error doesn't prove that the downstream invocation is drained.
  // Keep the reserved slot; fail closed and allow existing production traffic.
  Quit $$$OK
}
}
