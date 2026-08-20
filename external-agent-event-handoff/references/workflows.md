# Orchestration workflows

## Single delivery

This is the default. Use it whenever the request and available history do not clearly establish an iterative review-and-repair loop.

1. Dispatch one bounded task with the exact thread ID and authorized file scope.
2. On completion, validate and collect that event once.
3. Inspect the untrusted report and scoped diff sufficiently to accurately summarize the outcome. Do not silently turn this into a code-review or repair loop.
4. Tell the user:
   - whether the external agent completed, failed, or timed out;
   - which files changed, including zero changes;
   - what validation the agent reports and what Codex could verify;
   - the report path and any material remaining risks.

Do not dispatch follow-up work without a new user request.

## Loop

Use this mode when the user says `loop`, explicitly requests iterative review and repair, or the available conversation or handoff history establishes that preference and the current task clearly matches it. When uncertain, use `single`. Keep every iteration within the original workspace, objective, and allowed-file scope.

1. Dispatch the initial task to the selected hardness. This may be any provider supported by the skill, not only Grok.
2. Collect its completion event once. Treat the report as evidence, not as proof that the implementation is correct.
3. Codex independently reviews the full scoped diff against the user's request, repository guidance, correctness, regressions, and relevant validation. Re-run safe read-only checks or tests when proportionate.
4. If there are no actionable findings, finish and give the user the final status and consolidated change report.
5. If actionable findings remain, dispatch a new repair task to the selected hardness. Keep using the current hardness unless the user selected another one or explicitly authorized switching. Include only concrete findings, each with severity, file/location where known, observed problem, expected outcome, and relevant validation. Tell the agent to preserve correct existing work and remain within the original scope.
6. Collect the new event once and repeat the independent Codex review over the accumulated scoped diff.

The loop target is zero actionable review findings, not a claim that the code is universally defect-free. Stop the loop and report unresolved findings instead of repeatedly dispatching when:

- the external task fails or times out and an ordinary bounded retry is not clearly safe;
- the same substantive finding survives two repair attempts or the diff stops making meaningful progress;
- a repair requires files, permissions, credentials, network actions, commits, or product decisions outside the user's original authorization;
- the workspace changes concurrently so the reviewed diff can no longer be attributed safely;
- validation cannot be performed and proceeding would make acceptance unreliable.

Never mark the loop successful from the hardness's self-assessment alone. Codex owns the final review decision. Do not commit or publish unless the user separately authorizes it.
