Include %occStatus
/// Native tests for the gate-rejected human review task (EnsLib.Workflow).
/// Run: Do ##class(Storm.Tests).RunTests("Storm.WorkflowTests")
Class Storm.WorkflowTests Extends %UnitTest.TestCase
{

ClassMethod Fixture(cid As %String, rid As %String = "") As %String
{
  Set stream=##class(%Stream.FileCharacter).%New()
  Do stream.LinkToFile("/opt/storm/fixtures/"_cid_".json")
  Set obj=##class(%DynamicObject).%FromJSON(stream.Read(32767))
  Set:rid'="" obj.id=rid
  Quit obj.%ToJSON()
}

/// Background submitter for the concurrency test.
ClassMethod SubmitJob(rid As %String, payload As %String, n As %Integer)
{
  Set ^StormWFT(rid,n)="START"
  Set sc=##class(Storm.Service).Submit(rid,payload,.out)
  Set ^StormWFT(rid,n)=$Select($$$ISERR(sc):"ERROR",$IsObject(out):out.Status,1:"NONE")
}

Method Test1H12RejectedCreatesOneTask()
{
  Set rid="H12",payload=..Fixture("H12"),sc=##class(Storm.Service).Submit(rid,payload,.out)
  Do $$$AssertEquals(sc,1,"service status")
  Do $$$AssertEquals(out.Status,"FINAL","existing contract: rejected proposal still returns FINAL with rule grouping")
  Set res=##class(%DynamicObject).%FromJSON(out.Payload)
  Do $$$AssertEquals(res.%IsDefined("review"),0,"review side channel not in result payload")
  Do $$$AssertEquals(res.groups.%Size(),1,"rule grouping kept (AI split not applied)")
  Do $$$AssertEquals(##class(Storm.Process).Reconcile(rid),"FINAL","durable final receipt")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"exactly one review task")
  Do $$$AssertEquals(^Storm.Receipt(rid,"review"),"REQUESTED","review requested once")
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT ID FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ?",##class(Storm.Review).Subject(rid))
  Do rs.%Next() Set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(rs.ID)
  Do $$$AssertEquals(task.%RoleName,"Storm.Review","task routed to the Storm.Review role")
  Do $$$AssertTrue(task.%Message["Check 1: is the other alert caused by the same problem as the root?","task says what to check")
  Do $$$AssertTrue(task.%Message["other a2 [DB.Out.EHR]","task names the alert to check")
  Do $$$AssertTrue(task.%Message["does not change the stored root cause","task states no automatic feedback")
  Do $$$AssertEquals(task.%Actions["Confirm",0,"no confirm action offered")
}

Method Test2H12ResendStillOneTask()
{
  Set rid="H12",payload=..Fixture("H12"),before=$Get(^Storm.Receipt(rid,"result"))
  For i=1:1:3 { Set sc=##class(Storm.Service).Submit(rid,payload,.again) }
  Do $$$AssertEquals(again.Status,"FINAL","resend returns saved FINAL")
  Do $$$AssertEquals(again.Payload,before,"resend returns exact saved receipt")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"still exactly one review task after 3 resends")
}

Method Test3H12ConcurrentStillOneTask()
{
  Set rid="H12P",payload=..Fixture("H12",rid),n=4
  Kill ^StormWFT(rid)
  For i=1:1:n { Job ##class(Storm.WorkflowTests).SubmitJob(rid,payload,i) }
  For w=1:1:240 { Set done=0 For i=1:1:n { Set:$Case($Get(^StormWFT(rid,i)),"":0,"START":0,:1) done=done+1 } Quit:done=n  Hang 0.5 }
  Set final=0 For i=1:1:n { Set:$Get(^StormWFT(rid,i))="FINAL" final=final+1 }
  Do $$$AssertEquals(done,n,"all concurrent submissions returned")
  Do $$$LogMessage("concurrent statuses: "_$Get(^StormWFT(rid,1))_","_$Get(^StormWFT(rid,2))_","_$Get(^StormWFT(rid,3))_","_$Get(^StormWFT(rid,4)))
  Do $$$AssertTrue(final>=1,"at least one concurrent submission FINAL")
  Do $$$AssertEquals(##class(Storm.Process).Reconcile(rid),"FINAL","durable final receipt")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"exactly one review task for 4 concurrent arrivals")
}

Method Test4SuccessCasesCreateNoTask()
{
  Set list="A1,A2,A3,A4,A5,A6,C01,C02,C03,C04,C05,C06,C07,C08",ok=0
  For k=1:1:$Length(list,",") {
    Set cid=$Piece(list,",",k),rid=cid_"W",sc=##class(Storm.Service).Submit(rid,..Fixture(cid,rid),.out)
    Set:($$$ISOK(sc))&&(out.Status="FINAL") ok=ok+1
  }
  Do $$$AssertEquals(ok,14,"14 existing fixtures FINAL")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Set tasks=0,marks=0
  For k=1:1:$Length(list,",") { Set rid=$Piece(list,",",k)_"W",tasks=tasks+##class(Storm.Review).CountTasks(rid),marks=marks+$Data(^Storm.Receipt(rid,"review")) }
  Do $$$AssertEquals(tasks,0,"success cases create 0 review tasks")
  Do $$$AssertEquals(marks,0,"success cases have no review marker")
}

Method Test5FailureNotConfirmedNoTask()
{
  // H12 alerts with an unseen text: no recording exists, so the agent answer fails (no invented answer).
  Set rid="H12F",obj=##class(%DynamicObject).%FromJSON(..Fixture("H12",rid))
  Set a0=obj.alerts.%Get(0),a0.text=a0.text_" resent"
  Set sc=##class(Storm.Service).Submit(rid,obj.%ToJSON(),.out)
  Do $$$AssertEquals(out.Status,"UNKNOWN","failure is UNKNOWN, not FINAL")
  Do $$$AssertEquals(##class(Storm.Process).Reconcile(rid),"UNKNOWN","receipt not confirmed")
  Do $$$AssertEquals($Data(^Storm.Receipt(rid,"result")),0,"no result saved")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),0,"no review task on failure")
}

Method Test6RoleRestrictedToOneReviewer()
{
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS n FROM EnsLib_Workflow.RoleMembership WHERE RoleName = ?","Storm.Review")
  Do rs.%Next() Do $$$AssertEquals(+rs.n,1,"Storm.Review role has exactly one member")
  Do $$$AssertEquals(##class(EnsLib.Workflow.RoleMembership).%ExistsId("Storm.Review||stormreviewer"),1,"member is stormreviewer")
  // A Workflow user outside the role must not receive the task.
  If '##class(EnsLib.Workflow.UserDefinition).%ExistsId("stormoutsider") Do ##class(EnsLib.Workflow.UserDefinition).CreateUser("stormoutsider","not in role")
  Set subj=##class(Storm.Review).Subject("H12")
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT %ID AS id, UserName AS u FROM EnsLib_Workflow.Worklist WHERE Task->%Subject = ?",subj)
  Set items=0,other=0,item="" While rs.%Next() { Set items=items+1 Set:rs.u'="stormreviewer" other=other+1 Set item=rs.id }
  Do $$$AssertEquals(items,1,"one worklist item for the H12 task")
  Do $$$AssertEquals(other,0,"no worklist item for anyone outside the role")
  // Outsider's inbox: no worklist item at all for this storm.
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS n FROM EnsLib_Workflow.Worklist WHERE UserName = ?","stormoutsider")
  Do rs.%Next() Do $$$AssertEquals(+rs.n,0,"outsider inbox is empty")
  // The member takes ownership through its own worklist item.
  Do $$$AssertEquals($Piece(item,"||",2),"stormreviewer","worklist item belongs to stormreviewer")
  Set sc=##class(EnsLib.Workflow.Engine).%TakeOwnershipForTask(item,"stormreviewer",.msg)
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT ID FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ?",subj)
  Do rs.%Next() Set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(rs.ID)
  Do $$$AssertEquals(task.%TaskStatus.AssignedTo,"stormreviewer","role member owns the task")
  Set auto=##class(Ens.Director).GetItemSettingValue("Storm.DemoProduction||Storm.Review","Host","AutoCreateRole",.st)
  Do $$$AssertEquals(auto,0,"AutoCreateRole is off on the Workflow operation")
}

Method Test7HumanDecisionNotFedBack()
{
  Set rid="H12",before=^Storm.Receipt(rid,"result"),subj=##class(Storm.Review).Subject(rid)
  Set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT ID FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ?",subj)
  Do rs.%Next() Set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(rs.ID)
  // Reviewer acts from the Workflow inbox path (own worklist item, task owned in Test6).
  Set sc=##class(EnsLib.Workflow.Engine).%ProcessAction("Checked",rs.ID_"||stormreviewer","stormreviewer",.msg)
  Do $$$AssertEquals(sc,1,"reviewer action accepted")
  Do $$$LogMessage("ProcessAction msg="_$Get(msg))
  Hang 2
  Do task.%Reload()
  Do $$$AssertEquals(task.%TaskStatus.IsComplete,1,"task completed by reviewer")
  Do $$$AssertEquals(task.%Action,"Checked","reviewer action recorded on the task only")
  Do $$$AssertEquals(^Storm.Receipt(rid,"result"),before,"stored root cause unchanged after reviewer action")
  Do $$$AssertEquals(##class(Storm.Process).Reconcile(rid),"FINAL","receipt status unchanged")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"still one task")
}

/// Real contention: Storm.Process pool raised to 4 for this test only (restored to 1 after),
/// 4 simultaneous arrivals of one new storm id. The storm lock must be observed contended and one task created.
Method Test8RealContentionOneTask()
{
  Set rid="H12C",payload=..Fixture("H12",rid),n=4
  Kill ^StormWFT(rid),^Storm.Stat("lock_contended",rid)
  Do ..SetProcessPool(4)
  For i=1:1:n { Job ##class(Storm.WorkflowTests).SubmitJob(rid,payload,i) }
  For w=1:1:240 { Set done=0 For i=1:1:n { Set:$Case($Get(^StormWFT(rid,i)),"":0,"START":0,:1) done=done+1 } Quit:done=n  Hang 0.5 }
  Do ..SetProcessPool(1)
  Set final=0 For i=1:1:n { Set:$Get(^StormWFT(rid,i))="FINAL" final=final+1 }
  Do $$$LogMessage("pool=4 statuses: "_$Get(^StormWFT(rid,1))_","_$Get(^StormWFT(rid,2))_","_$Get(^StormWFT(rid,3))_","_$Get(^StormWFT(rid,4))_" lock_contended="_$Get(^Storm.Stat("lock_contended",rid),0))
  Do $$$AssertEquals(done,n,"all concurrent submissions returned")
  Do $$$AssertTrue($Get(^Storm.Stat("lock_contended",rid),0)>=1,"storm lock contention actually observed")
  Do $$$AssertTrue(final>=1,"at least one FINAL")
  Do $$$AssertEquals(##class(Storm.Process).Reconcile(rid),"FINAL","durable final receipt")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"exactly one review task under real contention")
  Do $$$AssertEquals(..ProcessPool(),1,"pool restored to 1")
}

ClassMethod ProcessPool() As %Integer
{
  Set prod=##class(Ens.Config.Production).%OpenId("Storm.DemoProduction"),size=""
  For i=1:1:prod.Items.Count() { Set it=prod.Items.GetAt(i) Set:it.Name="Storm.Process" size=it.PoolSize }
  Quit size
}

ClassMethod SetProcessPool(size As %Integer)
{
  Set prod=##class(Ens.Config.Production).%OpenId("Storm.DemoProduction")
  For i=1:1:prod.Items.Count() { Set it=prod.Items.GetAt(i) Set:it.Name="Storm.Process" it.PoolSize=size }
  Do prod.%Save()
  Do ##class(Ens.Director).UpdateProduction(30)
}

/// IPM install before the admin setup step: the role does not exist yet. The task is kept pending (SEND_FAILED,
/// nothing lost, no error task), and the first resend after Storm.Review.Setup() creates exactly one task.
Method Test9RoleMissingThenSetup()
{
  Set rid="H12S",payload=..Fixture("H12",rid)
  Do ##class(EnsLib.Workflow.RoleDefinition).RemoveUserFromRole("Storm.Review","stormreviewer")
  Do ##class(EnsLib.Workflow.RoleDefinition).%DeleteId("Storm.Review")
  Do $$$AssertEquals(##class(EnsLib.Workflow.RoleDefinition).%ExistsId("Storm.Review"),0,"role removed for this test")
  Set sc=##class(Storm.Service).Submit(rid,payload,.out),before=$Get(^Storm.Receipt(rid,"result"))
  Do $$$AssertEquals(out.Status,"FINAL","storm still FINAL without the role")
  Do $$$AssertEquals($Get(^Storm.Receipt(rid,"review")),"SEND_FAILED","review kept pending, not marked sent")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),0,"no task while the role is missing")
  Do $$$AssertEquals(##class(Storm.Review).Setup(),1,"admin setup step")
  Set sc=##class(Storm.Service).Submit(rid,payload,.again)
  Do $$$AssertEquals(again.Payload,before,"resend returns the saved result unchanged")
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"one task after setup and resend")
  Do $$$AssertEquals(^Storm.Receipt(rid,"review"),"REQUESTED","review marked requested")
  Set sc=##class(Storm.Service).Submit(rid,payload,.again)
  Do $$$AssertTrue(##class(Storm.Review).WaitQueue(),"workflow queue drained")
  Do $$$AssertEquals(##class(Storm.Review).CountTasks(rid),1,"still one task after another resend")
}

}
