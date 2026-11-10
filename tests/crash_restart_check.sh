#!/usr/bin/env bash
# Two-point stop/restart check for the gate-rejected review task (run on the host against an isolated stack).
#   STORM_PROJECT=stormwf ... docker compose -p stormwf up -d   (portal 127.0.0.1:52791)
#   bash tests/crash_restart_check.sh  > docs/workflow-crash-restart-run.txt
# Stop points: after_commit (FINAL committed, task not sent), after_send (send accepted, marker not updated),
# after_send:nosync (same point, journal tail not forced to disk, so the accepted send may be lost by the kill).
# For each stop point the IRIS container is SIGKILLed (no clean shutdown) while the Storm.Process job waits
# exactly at that point, then the stack is started again and the same storm is resent.
set -u
P=${P:-stormwf}; C=${P}-iris-1; COMPOSE=${COMPOSE:-docker compose -p $P -f docker-compose.yml -f /workspace/wf-run/override-idem.yml}
q(){ printf '%s\nHalt\n' "$1" | docker exec -i "$C" iris session IRIS -U USER 2>&1 | tr -d '\r' | grep -o 'OUT|.*'; }
H='Set h=$ZCVT(##class(%xsd.hexBinary).LogicalToXSD($System.Encryption.SHAHash(256,$Get(^Storm.Receipt(r,"result")))),"L")'
SNAP='Set s=##class(Storm.Review).Subject(r) Set x=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) n FROM EnsLib_Workflow.TaskRequest WHERE %Subject=?",s) Do x.%Next() Set nq=+x.n Set x=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) n FROM EnsLib_Workflow.TaskResponse WHERE %Subject=?",s) Do x.%Next() Set nt=+x.n Set x=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) n FROM EnsLib_Workflow.Worklist WHERE UserName=? AND Task->%Subject=?","stormreviewer",s) Do x.%Next() Set nw=+x.n '"$H"' Write "OUT|status=",$Get(^Storm.Receipt(r,"status"),"(none)")," review_marker=",$Get(^Storm.Receipt(r,"review"),"(none)")," task_ref=",$Get(^Storm.Receipt(r,"review","task"),"(none)")," recovered=",$Get(^Storm.Receipt(r,"review","recovered"),0)," task_requests=",nq," tasks=",nt," reviewer_inbox_items=",nw," result_sha256=",h,!'
wait_healthy(){ for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)" = healthy ] && return 0; sleep 3; done; echo "NOT HEALTHY"; return 1; }
drain(){ q 'Write "OUT|queue_drained=",##class(Storm.Review).WaitQueue(20),!'; }
echo "# $(date '+%Y-%m-%d %H:%M:%S %Z') project=$P container=$C"
echo "# image $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$C")"
echo "# source commit $(git rev-parse HEAD) (IRIS src baked into the image at build; tree clean for src/: $(git status --porcelain src | wc -l) changes)"
for spec in after_commit:H12A after_send:H12B after_send:nosync:H12N; do
  point=${spec%:*}; r=${spec##*:}
  echo; echo "== stop point: $point  storm id: $r (H12 fixture, new id) =="
  q "Kill ^Storm.Test(\"reached\",\"$r\") Set ^Storm.Test(\"crash\",\"$r\")=\"$point\" Write \"OUT|hook set\",!"
  q "Job ##class(Storm.WorkflowTests).SubmitJob(\"$r\",##class(Storm.WorkflowTests).Fixture(\"H12\",\"$r\"),1) Write \"OUT|submitted\",!"
  for i in $(seq 1 120); do got=$(q "Write \"OUT|\",\$Get(^Storm.Test(\"reached\",\"$r\")),!"); [ "$got" != "OUT|" ] && break; sleep 1; done
  echo "reached: ${got#OUT|}"
  echo -n "before kill:    "; q "Set r=\"$r\" $SNAP"
  pre=$(q "Set r=\"$r\" $H Write \"OUT|\",h,!"); pre=${pre#OUT|}
  docker kill -s KILL "$C" >/dev/null && echo "SIGKILL $C at $(date '+%H:%M:%S')"
  $COMPOSE start iris >/dev/null 2>&1; wait_healthy; $COMPOSE restart worker >/dev/null 2>&1
  echo "restarted, healthy at $(date '+%H:%M:%S'); production: $(q 'Set st=##class(Ens.Director).GetProductionStatus(.n,.s) Write "OUT|",n," state=",s,!')"
  sleep 5; drain >/dev/null
  echo -n "after restart:  "; q "Set r=\"$r\" $SNAP"
  for k in 1 2 3; do
    out=$(q "Set r=\"$r\",sc=##class(Storm.Service).Submit(r,##class(Storm.WorkflowTests).Fixture(\"H12\",r),.o) Write \"OUT|\",o.Status,\" \",\$ZCVT(##class(%xsd.hexBinary).LogicalToXSD(\$System.Encryption.SHAHash(256,o.Payload)),\"L\"),!")
    st=${out#OUT|}; echo "resend $k: status=${st%% *} payload_sha256=${st##* } byte_identical_to_pre_kill=$([ "${st##* }" = "$pre" ] && echo yes || echo NO)"
  done
  drain
  echo -n "final:          "; q "Set r=\"$r\" $SNAP"
done
echo; echo "== after the restarts: 14 normal fixtures (new ids *R) and 1 failure case (H12FR) =="
q 'Set ok=0,t=0,m=0,list="A1,A2,A3,A4,A5,A6,C01,C02,C03,C04,C05,C06,C07,C08" For k=1:1:14 { Set c=$P(list,",",k),r=c_"R",sc=##class(Storm.Service).Submit(r,##class(Storm.WorkflowTests).Fixture(c,r),.o) Set:$$$ISOK(sc)&&(o.Status="FINAL") ok=ok+1 } Write "OUT|normal FINAL=",ok,"/14",!'
q 'Set r="H12FR",obj=##class(%DynamicObject).%FromJSON(##class(Storm.WorkflowTests).Fixture("H12",r)),a=obj.alerts.%Get(0),a.text=a.text_" resent",sc=##class(Storm.Service).Submit(r,obj.%ToJSON(),.o) Write "OUT|failure status=",o.Status," saved_result=",$D(^Storm.Receipt(r,"result")),!'
drain
q 'Set t=0,m=0,list="A1R,A2R,A3R,A4R,A5R,A6R,C01R,C02R,C03R,C04R,C05R,C06R,C07R,C08R,H12FR" For k=1:1:15 { Set r=$P(list,",",k),t=t+##class(Storm.Review).CountTasks(r),m=m+$D(^Storm.Receipt(r,"review")) } Write "OUT|tasks for normal+failure=",t," review_markers=",m,!'
q 'Set x=##class(%SQL.Statement).%ExecDirect(,"SELECT %Subject s, COUNT(*) n FROM EnsLib_Workflow.TaskResponse GROUP BY %Subject ORDER BY %Subject") While x.%Next() { Write "OUT|all tasks: ",x.n,"x ",x.s,! }'
q 'Set x=##class(%SQL.Statement).%ExecDirect(,"SELECT Type, ConfigName, COUNT(*) n FROM Ens_Util.Log WHERE Type IN (2,3) GROUP BY Type, ConfigName") While x.%Next() { Write "OUT|event log type=",$Case(x.Type,2:"Error",3:"Warning",:x.Type)," host=",x.ConfigName," count=",x.n,! }'
q 'Set x=##class(%SQL.Statement).%ExecDirect(,"SELECT TOP 20 Type, ConfigName, Text FROM Ens_Util.Log WHERE Type = 2 ORDER BY ID") While x.%Next() { Write "OUT|error: ",x.ConfigName," ",$E(x.Text,1,160),! }'
