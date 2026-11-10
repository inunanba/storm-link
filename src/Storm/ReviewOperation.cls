Include (%occStatus, Ensemble)
/// Native IRIS Workflow operation for the Storm.Review role, made idempotent per task request.
/// After an unclean stop Ens can deliver the same TaskRequest again (in-flight message recovery);
/// the stock operation would then create a second task for one request. Here a redelivery reuses
/// the task already created for that request and only re-binds the deferred-response token.
Class Storm.ReviewOperation Extends EnsLib.Workflow.Operation
{

Method TaskHandler(pTask As EnsLib.Workflow.TaskRequest, Output pResponse As EnsLib.Workflow.TaskResponse) As %Status
{
  Set rq=pTask.%Id(),existing=""
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT TOP 1 ID FROM EnsLib_Workflow.TaskResponse WHERE TaskStatus_Request = ? ORDER BY ID",rq)
  If rs.%Next() Set existing=rs.ID
  If existing="" {
    Set sc=##super(pTask,.pResponse)
    // Test-only stop point (inactive unless the crash test sets it): task distributed, message not yet completed.
    If $$$ISOK(sc) Do ##class(Storm.Review).CrashPoint("op","after_distribute")
    Quit sc
  }
  Set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(existing)
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS n FROM EnsLib_Workflow.Worklist WHERE Task = ?",existing)
  Set items=$Select(rs.%Next():+rs.n,1:0)
  // A task saved before its worklist items were written (stop inside distribution) is replaced, not duplicated.
  If ('task.%TaskStatus.IsComplete)&&(task.%TaskStatus.AssignedTo="")&&(items=0) {
    Set sc=##class(EnsLib.Workflow.TaskResponse).%DeleteId(existing) Quit:$$$ISERR(sc) sc
    $$$LOGINFO("Task request "_rq_" redelivered; incomplete task "_existing_" had no worklist item and was replaced")
    Quit ##super(pTask,.pResponse)
  }
  Set sc=..DeferResponse(.token) Quit:$$$ISERR(sc) sc
  If 'task.%TaskStatus.IsComplete { Set task.%TaskStatus.ResponseToken=token,sc=task.%Save() Quit:$$$ISERR(sc) sc }
  $$$LOGINFO("Task request "_rq_" redelivered; reusing existing task "_existing_" (no second task)")
  Quit $$$OK
}

}
