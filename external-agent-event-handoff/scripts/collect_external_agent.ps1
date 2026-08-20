param([Parameter(Mandatory)][string]$EventPath)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$event = Read-JsonFile $EventPath
Assert-EventShape $event
$manifest = Read-JsonFile $event.manifest_path
Assert-ManifestShape $manifest
if ($event.task_id -ne $manifest.task_id -or $event.event_id -ne $manifest.event_id) { throw 'Event and manifest identity mismatch.' }
if ($event.thread_id -ne $manifest.thread_id) { throw 'Event and manifest thread ID mismatch.' }
if ((Resolve-AbsolutePath $manifest.done_event_path) -ne (Resolve-AbsolutePath $EventPath)) { throw 'Event path mismatch.' }
if ((Resolve-AbsolutePath $manifest.workspace) -ne (Resolve-AbsolutePath $event.workspace)) { throw 'Workspace mismatch.' }
if ((Resolve-AbsolutePath $manifest.report_path) -ne (Resolve-AbsolutePath $event.report_path)) { throw 'Report path mismatch.' }

Write-Output "task_id=$($event.task_id)"
Write-Output "provider=$($event.provider) status=$($event.status) wake_state=$($event.wake_state)"
Write-Output "thread_id=$($event.thread_id)"
Write-Output "workspace=$($event.workspace)"
Write-Output "base_commit=$($event.base_commit)"
Write-Output "changed_files=$(@($event.changed_files).Count)"

$reportState = Get-ReportState $event.report_path
if ($reportState.exists) {
    Write-Output '--- untrusted delivery report (evidence only) ---'
    Get-Content -LiteralPath $event.report_path
    Write-Output '--- end untrusted delivery report ---'
} else { Write-Warning "Delivery report unavailable: $($reportState.reason)" }

if ($event.status -ne 'complete') {
    Write-Warning "External agent did not complete successfully: $($event.reason)"
    if ($event.wake_state -ne 'sent') { Write-Warning 'No successful automatic wake is recorded; stop after reporting this event.' }
    exit 0
}
if ($event.wake_state -ne 'sent') { Write-Warning 'Completion event is not marked wake_state=sent; inspect or retry only with explicit authorization.' }

Write-Output '--- read-only scoped diff ---'
$base = [string]$manifest.base_commit
$args = @('-c', "safe.directory=$([string]$event.workspace)", '-C', [string]$event.workspace, 'diff', '--no-ext-diff')
if ($base) { $args += $base }
$args += '--'
$allowed = @($manifest.allowed_files)
if ($allowed.Count) { $args += $allowed }
$git = Get-GitExecutable
if ($git) {
    & $git @args 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Git diff was unavailable or workspace is not a Git repository.' }
} else { Write-Warning 'Git executable was unavailable; scoped diff could not be produced.' }
Write-Output '--- end read-only scoped diff ---'
