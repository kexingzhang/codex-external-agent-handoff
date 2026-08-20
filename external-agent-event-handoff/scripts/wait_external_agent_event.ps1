param(
    [Parameter(Mandatory)][string]$EventPath,
    [ValidateRange(1,604800)][int]$TimeoutSeconds = 3600
)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$eventFull = Resolve-AbsolutePath $EventPath
$eventDirectory = Split-Path -Parent $eventFull
$eventName = Split-Path -Leaf $eventFull
if (-not (Test-Path -LiteralPath $eventDirectory -PathType Container)) { throw "Event directory does not exist: $eventDirectory" }

$watcher = [IO.FileSystemWatcher]::new($eventDirectory, $eventName)
$watcher.NotifyFilter = [IO.NotifyFilters]::FileName
$watcher.EnableRaisingEvents = $true
try {
    if (-not (Test-Path -LiteralPath $eventFull)) {
        $changeTypes = [IO.WatcherChangeTypes]::Created -bor [IO.WatcherChangeTypes]::Renamed
        $change = $watcher.WaitForChanged($changeTypes, $TimeoutSeconds * 1000)
        if ($change.TimedOut) { throw "Timed out waiting for external-agent event: $eventFull" }
    }
} finally { $watcher.Dispose() }

$event = Read-JsonFile $eventFull
Assert-EventShape $event
$manifest = Read-JsonFile $event.manifest_path
Assert-ManifestShape $manifest
if ($event.task_id -ne $manifest.task_id -or $event.event_id -ne $manifest.event_id) { throw 'Event and manifest identity mismatch.' }
if ($event.thread_id -ne $manifest.thread_id) { throw 'Event and manifest thread ID mismatch.' }
if ((Resolve-AbsolutePath $manifest.done_event_path) -ne $eventFull) { throw 'Event path mismatch.' }
if ([string]$manifest.app_server.delivery_mode -ne 'wait') { throw 'Event was not dispatched with delivery_mode=wait.' }

$event.wake_state = 'sent'
Write-AtomicJson -Path $eventFull -Value $event | Out-Null
Write-AtomicJson -Path $manifest.state_path -Value ([ordered]@{ task_id = $event.task_id; event_id = $event.event_id; status = $event.status; wake_state = 'sent'; at = Get-NowUtc; reason = $event.reason }) | Out-Null
Write-Output $eventFull
