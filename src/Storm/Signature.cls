Include %occStatus
/// Storm signature memory: Embedded Python embeds alert text; IRIS VECTOR_COSINE finds similar past storms.
Class Storm.Signature Extends %RegisteredObject
{

ClassMethod EnsureSchema() As %Status
{
  Set st=##class(%SQL.Statement).%ExecDirect(,"CREATE TABLE IF NOT EXISTS Storm_Signature (StormId VARCHAR(64) PRIMARY KEY, Signature VARCHAR(4096), Embedding VECTOR(DOUBLE, 32), RootComponent VARCHAR(128), CreatedAt TIMESTAMP)")
  If st.%SQLCODE<0 Quit $$$ERROR($$$GeneralError,"Storm_Signature schema: "_st.%Message)
  Quit $$$OK
}

/// Deterministic bag-of-token embedding (32-dim) for offline replay; no external model required.
ClassMethod Embed(text As %String) As %String [ Language = python ]
{
    import hashlib
    import math
    import re
    dim = 32
    vec = [0.0] * dim
    tokens = re.findall(r"[A-Za-z0-9_.]+", (text or "").lower())
    for t in tokens:
        h = hashlib.sha256(t.encode("utf-8")).digest()
        idx = h[0] % dim
        sign = 1.0 if (h[1] % 2 == 0) else -1.0
        vec[idx] += sign
    n = math.sqrt(sum(x * x for x in vec)) or 1.0
    return ",".join(f"{x / n:.8f}" for x in vec)
}

ClassMethod SignatureText(payload As %String) As %String
{
  Set input=##class(%DynamicObject).%FromJSON(payload),parts=""
  For i=0:1:input.alerts.%Size()-1 {
    Set a=input.alerts.%Get(i)
    Set parts=parts_a.c_" "_a.text_" "
  }
  Quit $Extract(parts,1,4000)
}

/// Return "stormId:score" for the nearest past storm, or "" when none.
ClassMethod FindSimilar(stormId As %String, payload As %String) As %String [ Language = python ]
{
    import iris
    text = iris.cls(__name__).SignatureText(payload)
    emb = iris.cls(__name__).Embed(text)
    stmt = iris.sql.prepare(
        "SELECT TOP 1 StormId, VECTOR_COSINE(Embedding, TO_VECTOR(?, DOUBLE, 32)) AS Score "
        "FROM Storm_Signature WHERE StormId <> ? "
        "ORDER BY VECTOR_COSINE(Embedding, TO_VECTOR(?, DOUBLE, 32)) DESC"
    )
    rs = stmt.execute(emb, stormId, emb)
    for row in rs:
        sid = str(row[0])
        score = float(row[1]) if row[1] is not None else 0.0
        if score >= 0.55:
            return f"{sid}:{score:.4f}"
        return ""
    return ""
}

ClassMethod Record(stormId As %String, payload As %String, resultJson As %String) As %Status
{
  Set sc=..EnsureSchema() Quit:$$$ISERR(sc) sc
  Set text=..SignatureText(payload)
  Set emb=..Embed(text)
  Set root=""
  Try {
    Set state=##class(%DynamicObject).%FromJSON(resultJson)
    If state.groups.%Size()>0 {
      Set g=state.groups.%Get(0)
      Set input=##class(%DynamicObject).%FromJSON(payload)
      For i=0:1:input.alerts.%Size()-1 {
        Set a=input.alerts.%Get(i)
        If a.id=g.root Set root=a.c Quit
      }
    }
  } Catch {}
  Set st=##class(%SQL.Statement).%ExecDirect(,"DELETE FROM Storm_Signature WHERE StormId = ?",stormId)
  Set sql="INSERT INTO Storm_Signature (StormId, Signature, Embedding, RootComponent, CreatedAt) VALUES (?, ?, TO_VECTOR(?, DOUBLE, 32), ?, CURRENT_TIMESTAMP)"
  Set st=##class(%SQL.Statement).%ExecDirect(,sql,stormId,text,emb,root)
  If st.%SQLCODE<0 Quit $$$ERROR($$$GeneralError,"Storm_Signature insert: "_st.%Message_" code="_st.%SQLCODE)
  Quit $$$OK
}

}
