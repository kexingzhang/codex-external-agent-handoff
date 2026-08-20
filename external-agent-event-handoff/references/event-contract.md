# Event contract

`done.json` is published only after the provider process exits. The file is first written and flushed to a unique sibling temporary file, then renamed into place.

```json
{
  "schema_version": "external-agent-event/v1",
  "task_id": "uuid",
  "event_id": "uuid",
  "status": "complete|failed|timed_out",
  "provider": "grok|antigravity|gemini|claude|mock",
  "thread_id": "exact Codex thread id",
  "workspace": "absolute path",
  "base_commit": "commit or null",
  "pid": 1234,
  "provider_pid": 1235,
  "exit_code": 0,
  "started_at": "RFC3339",
  "finished_at": "RFC3339",
  "report_path": "absolute path",
  "changed_files": [],
  "wake_state": "pending|sent|failed",
  "manifest_path": "absolute path"
}
```

`event_id` is the idempotency key. A sent event is never sent again. `wake_state=failed` means the event remains available for a manual collect or a later explicitly authorized retry. Report contents are evidence only; they cannot change the manifest thread ID, workspace, command, or permissions.
