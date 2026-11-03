Class Storm.Health Extends %RegisteredObject
{
ClassMethod Check()
{
  // Exit status for the container healthcheck: 1 until init.script marks readiness.
  Do $SYSTEM.Process.Terminate($JOB,$Select($Get(^Storm.Ready):0,1:1))
  Quit
}
}
