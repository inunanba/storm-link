# Native IRIS features in Storm Link

Every feature below is exercised by `scripts/demo.sh` on IRIS 2026.3.0AI.154 (Community).

| Feature | Where | Why it is the right tool |
|---|---|---|
| Interoperability Production (Business Service → Business Process → Business Operation) | `Storm.DemoProduction`, `Storm.Service`, `Storm.Process`, `Storm.AgentOperation` | Each storm becomes one session, so the whole decision is auditable with the tools operators already use. |
| `%AI.Agent` + `%AI.Provider` (AI Hub) | `Storm.AgentOperation` | The model call is a native agent step inside the Production, not a side script; one bounded yes/no question per call, `MaxIterations=1`, no tools. |
| Visual Trace | Portal → Visual Trace, session per storm | Service → Process → Agent → Process → Service appears as one trace; the agent reply body carries `Model`, `ToolCalls`, `DurationMs` (and `Usage` when the live backend reports token counts). |
| Managed Alerts (`Ens.Alerting.ManagedAlert`, `UpdateManagedAlert`) | `Storm.Process` | Every original alert is kept; the root alert receives one action per related alert plus the AI evidence as the action reason, so on-call staff see the cause where they already triage. |
| Transactions + globals for a durable receipt | `^Storm.Receipt`, `TSTART/TCOMMIT` | Alerts, reasons and the final receipt commit together; resubmitting the same storm ID returns the saved receipt with zero new alerts or agent calls. |
| `%UnitTest` | `Storm.NativeTests`, entry `Storm.Tests.RunTests()` | 12 methods / 72 assertions on the native path: service status, FINAL workflow, durable receipt, idempotent resubmission. |

## Evidence (compose smoke run)

- Visual Trace of storm A1: [img/visual-trace-A1.png](img/visual-trace-A1.png)
- Agent step body with model/tool-call/duration fields: [img/agent-step-A1.png](img/agent-step-A1.png)
- Root Managed Alert with AI evidence in its action reason: [img/managed-alert-A1-root.png](img/managed-alert-A1-root.png)
- Message and alert export for sessions C01/A1: [trace-A1-C01.txt](trace-A1-C01.txt)
- Native test output: [native-test-run.txt](native-test-run.txt)

```mermaid
sequenceDiagram
  participant S as Storm.Service
  participant P as Storm.Process
  participant W as Worker (graph)
  participant A as Storm.Agent (%AI.Agent)
  participant M as ManagedAlert
  S->>P: storm A1 (3 alerts)
  P->>W: /start (topology grouping)
  W-->>P: QUESTION (root conflict)
  P->>A: yes/no question 1
  A-->>P: ANSWER yes (model, tool calls 0)
  P->>A: yes/no question 2
  A-->>P: ANSWER yes
  P->>W: /answer x2
  W-->>P: FINAL: one group, root DB.Out.EHR
  P->>M: save 3 alerts + 4 reasons on root (one transaction)
  P-->>S: FINAL receipt
```
