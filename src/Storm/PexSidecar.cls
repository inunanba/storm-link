Include %occStatus

/// One outstanding Java call per isolated namespace. No automatic retry.
/// Submit from Storm.Process; dispatch and finish only in Storm.PexDispatch.
Class Storm.PexSidecar Extends %RegisteredObject
{
ClassMethod Now() As %Numeric
{
  Set z=$ZTimestamp
  Quit ($Piece(z,",",1)*86400)+$Piece(z,",",2)
}

ClassMethod Submit(host As Ens.BusinessProcess, rid As %String, result As %DynamicObject)
{
  // No wait on the global gate, and no synchronous Java invocation.
  Lock +^Storm.PexHandoff("slot"):0
  Quit:'$Test
  Try {
    If ('$Data(^Storm.PexHandoff("slot")))&&('$Data(^Storm.PexHandoff("state",rid))) {
      Set groups=..GroupRefs(rid,result)
      If groups'="" {
        Set req=##class(Storm.PexRequest).%New(),req.StormId=rid,req.Groups=groups
        // Reserve before dispatch. An ambiguous send stays reserved until explicit reconciliation.
        Set ^Storm.PexHandoff("state",rid)="QUEUED",^Storm.PexHandoff("deadline",rid)=..Now()+5
        Set ^Storm.PexHandoff("slot")=rid
        // ResponseRequired=0: the core BP cannot implicitly wait for the Java reply.
        Set sc=host.SendRequestAsync("Storm.PexDispatch",req,0,,"Optional handoff "_rid)
        If $$$ISERR(sc) Set ^Storm.PexHandoff("state",rid)="DISPATCH_UNKNOWN"
      }
    }
  } Catch {
    If $Get(^Storm.PexHandoff("slot"))=rid Set ^Storm.PexHandoff("state",rid)="DISPATCH_UNKNOWN"
  }
  Lock -^Storm.PexHandoff("slot")
}

ClassMethod Dispatch(host As Ens.BusinessProcess, req As Storm.PexRequest)
{
  Set rid=req.StormId
  Lock +^Storm.PexHandoff("slot"):1
  Quit:'$Test
  Try {
    If ($Get(^Storm.PexHandoff("slot"))=rid)&&($Get(^Storm.PexHandoff("state",rid))="QUEUED") {
      If ..Now()>=$Get(^Storm.PexHandoff("deadline",rid)) {
        Set ^Storm.PexHandoff("state",rid)="EXPIRED"
        Kill ^Storm.PexHandoff("slot")
      } Else {
        // On redelivery, never repeat an invocation with an uncertain outcome.
        Set ^Storm.PexHandoff("state",rid)="IN_FLIGHT"
        Set sc=host.SendRequestAsync("Storm.JavaHandoff",req,1,"StormJavaHandoff","Format Managed Alert references")
        If $$$ISERR(sc) Set ^Storm.PexHandoff("state",rid)="DISPATCH_UNKNOWN"
      }
    }
  } Catch {
    If $Get(^Storm.PexHandoff("slot"))=rid Set ^Storm.PexHandoff("state",rid)="DISPATCH_UNKNOWN"
  }
  Lock -^Storm.PexHandoff("slot")
}

ClassMethod Finish(rid As %String, reply As %Library.Persistent)
{
  Quit:'$IsObject(reply)
  Quit:'reply.%IsA("Storm.PexReply")
  Lock +^Storm.PexHandoff("slot"):1
  Quit:'$Test
  Try {
    If ($Get(^Storm.PexHandoff("slot"))=rid)&&($Get(^Storm.PexHandoff("state",rid))="IN_FLIGHT") {
      If ..Now()>=$Get(^Storm.PexHandoff("deadline",rid)) {
        Set ^Storm.PexHandoff("state",rid)="EXPIRED"
      } Else {
        Set ^Storm.PexHandoff("state",rid)="FAILED"
        If reply.Card'="" {
          Set ^Storm.PexHandoff("card",rid)=reply.Card
          Set ^Storm.PexHandoff("state",rid)="READY"
        }
      }
      Kill ^Storm.PexHandoff("slot")
    }
  } Catch {
    // Leave the slot reserved if local completion is ambiguous.
  }
  Lock -^Storm.PexHandoff("slot")
}

/// No read access to raw alerts or model responses. Empty means skip.
ClassMethod GroupRefs(rid As %String, result As %DynamicObject) As %String
{
  Set out="",groups=result.groups
  Quit:(groups.%Size()<1)!(groups.%Size()>32) ""
  For i=0:1:groups.%Size()-1 {
    Set group=groups.%Get(i),root=$Get(^Storm.Receipt(rid,"alert",group.root))
    If '((root?1.N)&&(root>0)&&($Length(root)'>18)) Return ""
    Set members=group.members,row="",n=members.%Size()
    If (n<1)!(n>64) Return ""
    For j=0:1:n-1 {
      Set id=$Get(^Storm.Receipt(rid,"alert",members.%Get(j)))
      If '((id?1.N)&&(id>0)&&($Length(id)'>18)) { Set row="" Quit }
      Set row=row_$Select(j:",",1:"")_id
    }
    If row="" Return ""
    Set out=out_$Select(i:";",1:"")_root_":"_row
    If $Length(out)>2048 Return ""
  }
  Quit out
}

ClassMethod Status(rid As %String) As %String
{
  Set state=$Get(^Storm.PexHandoff("state",rid),"NOT_GENERATED")
  If ((state="QUEUED")||(state="IN_FLIGHT"))&&(..Now()>=$Get(^Storm.PexHandoff("deadline",rid))) Quit "EXPIRED_PENDING_DRAIN"
  Quit state
}

ClassMethod Card(rid As %String) As %String
{
  Quit:..Status(rid)'="READY" ""
  Quit $Get(^Storm.PexHandoff("card",rid))
}
}
