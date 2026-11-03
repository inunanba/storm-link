Include %occStatus
Class Storm.Service Extends Ens.BusinessService
{
Method OnProcessInput(pInput As Storm.Message, Output pOutput As Storm.Reply) As %Status
{
  Quit ..SendRequestSync("Storm.Process",pInput,.pOutput,120)
}
ClassMethod Submit(rid As %String, payload As %String, Output out As Storm.Reply) As %Status
{
  Set sc=##class(Ens.Director).CreateBusinessService("Storm.Service",.bs)
  Quit:$$$ISERR(sc) sc
  Set req=##class(Storm.Message).%New(),req.StormId=rid,req.Payload=payload
  Quit bs.ProcessInput(req,.out)
}
}
