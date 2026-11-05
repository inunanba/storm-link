Include %occStatus
/// Business Operation that calls the private worker through Storm.WorkerAdapter.
Class Storm.WorkerOperation Extends Ens.BusinessOperation
{
Parameter ADAPTER = "Storm.WorkerAdapter";
Parameter INVOCATION = "InProc";

Method CallWorker(pRequest As Storm.WorkerRequest, Output pResponse As Storm.WorkerReply) As %Status
{
  Set pResponse=##class(Storm.WorkerReply).%New()
  Set obj=..Adapter.PostJSON(pRequest.Path,pRequest.Body)
  Set pResponse.Body=obj.%ToJSON()
  Quit $$$OK
}

XData MessageMap
{
<MapItems><MapItem MessageType="Storm.WorkerRequest"><Method>CallWorker</Method></MapItem></MapItems>
}
}
