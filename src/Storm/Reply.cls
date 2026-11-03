Class Storm.Reply Extends Ens.Response
{
Property Status As %String;
Property Payload As %String(MAXLEN = 32767);
/// Agent step details shown in Visual Trace: backend model, token usage (live only), tool calls, duration.
Property Model As %String(MAXLEN = 200);
Property Usage As %String(MAXLEN = 500);
Property ToolCalls As %Integer;
Property DurationMs As %Integer;
}
