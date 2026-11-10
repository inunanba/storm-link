Include %occStatus
/// Human review via native IRIS Workflow (EnsLib.Workflow) for one case only:
/// the AI root-cause proposal was rejected by the deterministic gate.
/// The task carries what to check. The reviewer's decision is NOT fed back into the stored root cause.
Class Storm.Review Extends %RegisteredObject
{

/// Workflow role = config name of the EnsLib.Workflow.Operation item in Storm.DemoProduction.
Parameter ROLE = "Storm.Review";

/// The single Workflow user allowed in the role.
Parameter REVIEWER = "stormreviewer";

/// Creates the role and its one member (idempotent). AutoCreateRole is off on the operation.
ClassMethod Setup() As %Status
{
  Set sc=$$$OK
  If '##class(EnsLib.Workflow.RoleDefinition).%ExistsId(..#ROLE) {
    Set sc=##class(EnsLib.Workflow.RoleDefinition).CreateRole(..#ROLE) Quit:$$$ISERR(sc) sc
  }
  If '##class(EnsLib.Workflow.UserDefinition).%ExistsId(..#REVIEWER) {
    Set sc=##class(EnsLib.Workflow.UserDefinition).CreateUser(..#REVIEWER,"Storm Link reviewer") Quit:$$$ISERR(sc) sc
  }
  If '##class(EnsLib.Workflow.RoleMembership).%ExistsId(..#ROLE_"||"_..#REVIEWER) {
    Set sc=##class(EnsLib.Workflow.RoleDefinition).AddUserToRole(..#ROLE,..#REVIEWER,1,"Reviewer")
  }
  Quit sc
}

ClassMethod Subject(rid As %String) As %String
{
  Quit "Storm "_rid_": AI root-cause proposal rejected by gate - human check"
}

/// Builds the task text from the worker's gate review and the original alerts.
ClassMethod BuildTask(rid As %String, review As %DynamicObject) As EnsLib.Workflow.TaskRequest
{
  Set task=##class(EnsLib.Workflow.TaskRequest).%New()
  Set task.%Subject=..Subject(rid),task.%Priority=2
  // Custom actions only; there is deliberately no "Confirm" action.
  Set task.%Actions="Checked,NeedsEngineer"
  Set nl=$Char(13,10)
  Set msg="Storm "_rid_": the AI proposal for this alert group was rejected by the Storm Link gate."_nl
  Set msg=msg_"Stored result keeps the topology-rule grouping unchanged. Nothing in this storm was confirmed by AI."_nl
  Set msg=msg_"This task does not change the stored root cause; record your finding in your own process."_nl
  For g=0:1:review.groups.%Size()-1 {
    Set grp=review.groups.%Get(g),members=""
    For m=0:1:grp."kept_members".%Size()-1 Set members=members_$Select(m:",",1:"")_grp."kept_members".%Get(m)
    Set msg=msg_nl_"Kept group: root "_grp."kept_root"_", members "_members_nl
    For k=0:1:grp.checks.%Size()-1 {
      Set c=grp.checks.%Get(k)
      Set msg=msg_"Check "_(k+1)_": "_$Select(c.kind="ROOT":"is the upstream alert only a symptom of the downstream one?",1:"is the other alert caused by the same problem as the root?")_nl
      Set msg=msg_"  root "_c.root_" ["_c."root_alert".c_"] "_c."root_alert".text_nl
      Set msg=msg_"  other "_c.member_" ["_c."member_alert".c_"] "_c."member_alert".text_nl
      Set msg=msg_"  AI answered "_c."ai_answer"_": "_$Extract(c."ai_reason",1,300)_nl
    }
  }
  Set task.%Message=msg
  Quit task
}

/// Existing task for this storm id, matched exactly on the stored storm id in the subject.
/// Checks the persisted task request first (exists as soon as the send is accepted, even if still queued),
/// then delivered tasks. Returns "" when none exists.
ClassMethod FindTask(rid As %String) As %String
{
  Set subj=..Subject(rid)
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT TOP 1 ID FROM EnsLib_Workflow.TaskRequest WHERE %Subject = ? ORDER BY ID",subj)
  Quit:rs.%Next() "request:"_rs.ID
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT TOP 1 ID FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ? ORDER BY ID",subj)
  Quit:rs.%Next() "task:"_rs.ID
  Quit ""
}

/// Test-only stop point. Inactive unless ^Storm.Test("crash",rid) names this point (set only by the crash test).
/// One-shot: the hook is cleared and the arrival is recorded in a committed transaction,
/// then the job waits so the test can kill the whole IRIS container at exactly this point.
/// Hook value "<point>" also flushes the journal (everything done up to the point is on disk);
/// "<point>:nosync" does not (an unflushed tail may be lost by the kill).
ClassMethod CrashPoint(rid As %String, point As %String)
{
  Set hook=$Get(^Storm.Test("crash",rid))
  Quit:$Piece(hook,":")'=point
  Set tl=$TLEVEL
  TStart
  Kill ^Storm.Test("crash",rid)
  Set ^Storm.Test("reached",rid)=hook_" tlevel_at_entry="_tl_" "_$ZDT($ZTS,3,,3)
  TCommit
  If hook'[":nosync" Do ##class(%SYS.Journal.System).Sync()
  Hang 120
}

/// Number of Workflow tasks created for this storm.
ClassMethod CountTasks(rid As %String) As %Integer
{
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS n FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ?",..Subject(rid))
  Quit:'rs.%Next() 0
  Quit +rs.n
}

/// Waits until the Workflow operation queue has stayed empty for 1 second (async delivery).
ClassMethod WaitQueue(seconds As %Integer = 15) As %Boolean
{
  Set quiet=0
  For i=1:1:seconds*4 {
    Set quiet=$Select(##class(Ens.Queue).GetCount(..#ROLE)=0:quiet+1,1:0)
    Quit:quiet>=4
    Hang 0.25
  }
  Quit quiet>=4
}

}
