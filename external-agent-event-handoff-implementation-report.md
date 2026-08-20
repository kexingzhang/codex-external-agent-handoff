# External Agent Event Handoff — implementation report

Date: 2026-08-20 (Asia/Shanghai)

## Delivered

Installed personal Skill:

`C:\Users\KXzhang\.codex\skills\external-agent-event-handoff\`

Files:

- `SKILL.md`
- `agents/openai.yaml`
- `references/event-contract.md`
- `scripts/common.ps1`
- `scripts/dispatch_external_agent.ps1`
- `scripts/run_external_agent.ps1`
- `scripts/wake_codex.ps1`
- `scripts/collect_external_agent.ps1`
- `scripts/mock_provider.ps1`
- `tests/mock_app_server.ps1`
- `tests/mock_app_server_unavailable.ps1`
- `tests/run-tests.ps1`

The workspace copy used for review is `D:\AI\codex-to-other-hardnesss\external-agent-event-handoff\`.

## Behavior

`dispatch` requires an explicit, exact `thread_id`, absolute workspace, report path outside the workspace, and an explicit provider argument array for Grok/Gemini/Claude. It never guesses a provider CLI subcommand. Individual arguments can use `{prompt_file}`, `{workspace}`, `{report_path}`, and `{task_id}`. The mock provider is local-only and does not call a paid model.

The wrapper waits on the external process once, verifies the final report, atomically publishes `<task-id>.done.json`, and invokes the wake script only after provider exit. The completion prompt contains only task/event/report paths; report contents are never injected into `turn/start`.

The wake script uses the manifest's exact thread ID and the verified sequence:

1. `initialize`
2. `initialized`
3. `thread/resume`
4. `turn/start`

It refuses an active target thread, a returned thread ID mismatch, unavailable direct input, a complete event without a final report, or an unavailable App Server. `wake_state=sent` is idempotent and prevents a second `turn/start`.

`collect` validates the manifest/event relationship and performs read-only report and scoped diff inspection. Report text is explicitly treated as untrusted evidence. It does not modify, stage, commit, or execute report instructions.

## Local capability verification

- Desktop package identity: `OpenAI.Codex` version `26.814.5517.0`.
- Configured CLI path was found in the existing Codex configuration and executed directly.
- CLI version: `codex-cli 0.148.0-alpha.15`.
- `codex app-server --help` verified `stdio://`, `unix://`, `ws://`, `thread/resume` support through the generated protocol, and the `daemon` command.
- `codex app-server generate-json-schema --experimental` generated version-specific schemas in `D:\AI\codex-to-other-hardnesss\.codex-app-server-schema`. The schemas contain `initialize`, `initialized`, `thread/resume`, and `turn/start`.
- A real CLI App Server initialize probe returned a JSON-RPC response with `Codex Desktop/0.148.0-alpha.15` and Windows platform metadata. No real model turn was started.
- Windows `codex app-server daemon version` reported that daemon lifecycle is Unix-only. The implementation therefore uses a one-shot stdio App Server process after provider completion.

Official documentation used:

- [Codex App Server](https://developers.openai.com/codex/app-server/)
- [Build skills](https://developers.openai.com/codex/skills/)
- [Scheduled tasks](https://learn.chatgpt.com/docs/automations)

## Tests

Command:

```powershell
& pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\Users\KXzhang\.codex\skills\external-agent-event-handoff\tests\run-tests.ps1'
```

Result: PASS, exit code 0.

Covered by the mock harness:

- success → report → done event → exactly one wake;
- non-zero provider exit → failed event → one wake;
- timeout → timed_out event → one wake;
- missing report cannot become complete;
- replayed event does not send a second `turn/start`;
- returned thread ID mismatch fails closed;
- App Server unavailable fails closed after the bounded attempt;
- workspace/report paths include spaces, Chinese characters, and brackets;
- mock JSONL handshake and method order are checked;
- provider runs before the App Server wake path.

The bundled `quick_validate.py` was inspected, but could not execute because the available bundled Python lacks the optional `PyYAML` module. Manual validation confirmed the required frontmatter, hyphenated skill name, description, and absence of unfinished TODO scaffolding. No dependency was installed.

## Configuration and safety

No Codex configuration was edited. The existing `C:\Users\KXzhang\.codex\config.toml` remained unchanged during implementation; final observed SHA-256 was `A3DAF34854B8E8C29AC1E6976B84AFD7FF9DA284EE61C1B55D5E66982D6F3753`.

The skill does not store API keys, OAuth tokens, or report contents in the manifest. Credential-looking literals in provider/App Server argument arrays are rejected; existing CLI authentication is inherited from the process environment. No Git stage, commit, reset, clean, switch, merge, rebase, push, or real paid provider call was made.

## Known limitations

- The Grok CLI was not invoked or assumed. A real Grok dispatch must provide the locally verified executable and its exact argument array. This is deliberate fail-closed behavior because this machine does not provide a verified Grok command contract in the task context.
- The restricted shell could initialize the real App Server but could not use the actual user `CODEX_HOME` state directory for a real `thread/resume`; it returned the sandbox-offline home during the probe. Consequently, real-thread resume was validated from the generated protocol and a mock server, not against a live user thread.
- If Desktop/App Server is unavailable, or if the target thread is active, the event is retained with `wake_state=failed` for manual `collect` or an explicitly authorized retry.
- The user must supply the exact `thread_id`; this Skill intentionally does not discover or infer it.
- After installing a new local Skill, Codex may need a restart if it does not appear immediately in the picker.

No Git commit was created.
