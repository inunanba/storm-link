Include %occStatus
Class Storm.Process Extends Ens.BusinessProcess
{
Method OnRequest(pRequest As Storm.Message, Output pResponse As Storm.Reply) As %Status
{
  Set pResponse=##class(Storm.Reply).%New(),pResponse.Status="UNKNOWN",tx=0
  Set rid=pRequest.StormId,allowed="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  If ($Length(rid)<1)!($Length(rid)>64)!($Translate(rid,allowed)'="") Quit $$$ERROR($$$GeneralError,"invalid storm id")
  If $TLEVEL Quit $$$ERROR($$$GeneralError,"outer transaction not supported")
  Lock +^Storm.Receipt(rid):5
  If '$TEST Quit $$$ERROR($$$GeneralError,"storm in progress; reconcile")
  Try {
    If $Data(^Storm.Receipt(rid,"input")) {
      If ^Storm.Receipt(rid,"input")'=pRequest.Payload {
        Set pResponse.Status="CONFLICT",pResponse.Payload="storm id bound to another input"
      } Else {
        Set pResponse.Status=^Storm.Receipt(rid,"status"),pResponse.Payload=$Get(^Storm.Receipt(rid,"result"),"reconcile; no rerun")
      }
    } Else {
      Set input=##class(%DynamicObject).%FromJSON(pRequest.Payload)
      If input.id'=rid { Throw ##class(%Exception.General).%New("storm id mismatch") }
      // Durable intent before agent/worker call. Interrupted work is not blindly retried.
      TStart
      Set tx=1,^Storm.Receipt(rid,"input")=pRequest.Payload,^Storm.Receipt(rid,"status")="PROCESSING"
      TCommit
      Set tx=0
      Set state=..CallWorker("/start",pRequest.Payload),steps=0
      While state.status="QUESTION" {
        Set steps=steps+1
        If steps>64 { Throw ##class(%Exception.General).%New("question bound exceeded") }
        Set req=##class(Storm.Message).%New(),req.StormId=rid
        Set req.Payload="STORM_TICKET="_state.token_":"_state.question.id_$Char(10)_"MODE="_state.mode_$Char(10)_state.question.text
        Set sc=..SendRequestSync("Storm.Agent",req,.reply,110)
        If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("agent transport failed") }
        If '$IsObject(reply) { Throw ##class(%Exception.General).%New("no agent reply") }
        If reply.Status'="ANSWER" { Throw ##class(%Exception.General).%New("agent answer unknown") }
        Set value=##class(%DynamicObject).%FromJSON(reply.Payload)
        Set body={"token":(state.token),"question_id":(state.question.id),"answer":(value)}
        Set state=..CallWorker("/answer",body.%ToJSON())
      }
      If state.status'="FINAL" { Throw ##class(%Exception.General).%New("worker result not final") }
      // Gate-rejected AI proposal: kept out of the decision/result contract, used only for a human review task.
      Set review=""
      If state.%IsDefined("review") { Set review=state.review Do state.%Remove("review") }
      // Best-effort similar-storm lookup (Embedded Python + VECTOR_COSINE); never blocks the receipt.
      Set similar=""
      Try {
        Do ##class(Storm.Signature).EnsureSchema()
        Set similar=##class(Storm.Signature).FindSimilar(rid,pRequest.Payload)
      } Catch {}
      // One transaction: original alerts, root/child reasons and the final receipt.
      TStart
      Set tx=1
      For i=0:1:input.alerts.%Size()-1 {
        Set item=input.alerts.%Get(i),alert=##class(Ens.Alerting.ManagedAlert).%New()
        Set alert.SourceConfigName=item.c,alert.AlertText=item.text,alert.AlertTime=$ZDT($ZTS,3),alert.Production="Storm.DemoProduction"
        Set sc=alert.%Save()
        If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("managed alert save failed") }
        Set ids(item.id)=alert.%Id()
      }
      For i=0:1:state.groups.%Size()-1 {
        Set group=state.groups.%Get(i),root=group.root
        If '$Data(ids(root)) { Throw ##class(%Exception.General).%New("unknown root id") }
        For j=0:1:group.members.%Size()-1 {
          Set child=group.members.%Get(j)
          If '$Data(ids(child)) { Throw ##class(%Exception.General).%New("unknown child id") }
          // Action 1 is a reason log entry, not an assertion of Reoccurrence semantics.
          // No close, acknowledge, notification suppression or external action.
          If child=root { Set ^Storm.Receipt(rid,"alert",child)=ids(child) Continue }
          Set reason="Storm "_rid_"; root alert="_ids(root)_"; related alert="_ids(child)_"; mode="_state.mode_"; topology="_state."topology_hash"
          Set sc=##class(Ens.Alerting.ManagedAlert).UpdateManagedAlert(ids(root),1,,reason)
          If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("managed alert reason failed") }
          Set ^Storm.Receipt(rid,"alert",child)=ids(child)
        }
      }
      Set iter=state.answers.%GetIterator()
      While iter.%GetNext(.qid,.ans) {
        // Storm-level AI evidence, explicitly not a per-child causal assertion.
        Set reason="Storm "_rid_"; question="_qid_"; answer="_ans.answer_"; "_$Extract(ans.reason,1,200)
        Set group=state.groups.%Get(0)
        Set sc=##class(Ens.Alerting.ManagedAlert).UpdateManagedAlert(ids(group.root),1,,reason)
        If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("AI evidence reason save failed") }
      }
      If similar'="" {
        Set group=state.groups.%Get(0)
        Set reason="Storm "_rid_"; similar past storm="_similar
        Set sc=##class(Ens.Alerting.ManagedAlert).UpdateManagedAlert(ids(group.root),1,,reason)
        If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("similar-storm reason save failed") }
        Set ^Storm.Receipt(rid,"similar")=similar
      }
      If $IsObject(review) { Set ^Storm.Receipt(rid,"review")="PENDING",^Storm.Receipt(rid,"review","detail")=review.%ToJSON() }
      Set ^Storm.Receipt(rid,"result")=state.%ToJSON(),^Storm.Receipt(rid,"status")="FINAL"
      TCommit
      Set tx=0,pResponse.Status="FINAL",pResponse.Payload=state.%ToJSON()
      // Still under the storm lock and only on the first FINAL: at most one review task per storm.
      If $IsObject(review) Do ..RequestReview(rid,review)
      Try { Do ##class(Storm.Signature).Record(rid,pRequest.Payload,state.%ToJSON()) } Catch {}
    }
  } Catch ex {
    If tx { TRollback 1 Set tx=0 }
    Set ^Storm.Receipt(rid,"status")="UNKNOWN"
    Set pResponse.Status="UNKNOWN",pResponse.Payload="original storm requires reconciliation; no automatic retry"
  }
  Lock -^Storm.Receipt(rid)
  Quit $$$OK
}
/// One native Workflow task (EnsLib.Workflow.Operation "Storm.Review"); fire-and-forget, no response is awaited,
/// so the reviewer's decision never flows back into this storm's root cause. Never throws.
Method RequestReview(rid As %String, review As %DynamicObject)
{
  Try {
    If $Get(^Storm.Receipt(rid,"review"))'="PENDING" Quit
    Set task=##class(Storm.Review).BuildTask(rid,review)
    Set sc=..SendRequestAsync(##class(Storm.Review).#ROLE,task,0,,"Storm "_rid_" human review")
    Set ^Storm.Receipt(rid,"review")=$Select($$$ISOK(sc):"REQUESTED",1:"SEND_FAILED")
  } Catch {
    Set ^Storm.Receipt(rid,"review")="SEND_FAILED"
  }
}
Method CallWorker(path As %String, body As %String) As %DynamicObject
{
  Set req=##class(Storm.WorkerRequest).%New(),req.Path=path,req.Body=body
  Set sc=..SendRequestSync("Storm.WorkerOp",req,.reply,100)
  If $$$ISERR(sc) { Throw ##class(%Exception.General).%New("worker transport failed") }
  If '$IsObject(reply) { Throw ##class(%Exception.General).%New("no worker reply") }
  Quit ##class(%DynamicObject).%FromJSON(reply.Body)
}
ClassMethod Reconcile(rid As %String) As %String
{
  Set allowed="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  If ($Length(rid)<1)!($Length(rid)>64)!($Translate(rid,allowed)'="") Quit "UNKNOWN"
  Quit $Get(^Storm.Receipt(rid,"status"),"UNKNOWN")
}
}
