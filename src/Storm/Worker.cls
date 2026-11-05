Include %occStatus
/// Compatibility helper. Production traffic uses Storm.WorkerOperation + Storm.WorkerAdapter.
Class Storm.Worker Extends %RegisteredObject
{
ClassMethod Call(path As %String, body As %String) As %DynamicObject
{
  Set adapter=##class(Storm.WorkerAdapter).%New()
  Do adapter.OnInit()
  Quit adapter.PostJSON(path,body)
}
}
