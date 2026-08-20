param(
    [Parameter(Mandatory)][string]$EventPath,
    [ValidateRange(1,20)][int]$MaxAttempts = 3
)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

function Send-JsonLine($Proc, $Value) {
    $Proc.StandardInput.WriteLine(($Value | ConvertTo-Json -Depth 30 -Compress))
    $Proc.StandardInput.Flush()
}
function Read-Response($Proc, [int]$Id, [int]$TimeoutSeconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $task = $Proc.StandardOutput.ReadLineAsync()
        while (-not $task.IsCompleted) {
            if ($Proc.HasExited) { throw "App Server exited before response id=$Id." }
            $remaining = [Math]::Max(1, [int]([TimeSpan]($deadline - [DateTime]::UtcNow)).TotalMilliseconds)
            [void]$task.Wait([Math]::Min(1000, $remaining))
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for App Server response id=$Id." }
        }
        $line = $task.GetAwaiter().GetResult()
        if ($null -eq $line) { throw 'App Server closed stdout before the expected response.' }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($null -ne $message.id -and [int]$message.id -eq $Id) { return $message }
    }
    throw "Timed out waiting for App Server response id=$Id."
}
function Set-EventWakeState($Event, [string]$State) {
    $Event.wake_state = $State
    Write-AtomicJson -Path $EventPath -Value $Event | Out-Null
}
function Notify-Pending($Event) {
    $message = "Codex external-agent event is pending: $($Event.task_id). Run collect_external_agent.ps1 with $EventPath"
    Write-Warning $message
    $msg = Get-Command msg.exe -ErrorAction SilentlyContinue
    if ($msg -and $env:USERNAME) { & $msg.Source $env:USERNAME $message 2>$null | Out-Null }
}

$event = Read-JsonFile $EventPath
Assert-EventShape $event
if ($event.wake_state -eq 'sent') { Write-Output "already sent: $($event.event_id)"; exit 0 }
$manifest = Read-JsonFile $event.manifest_path
Assert-ManifestShape $manifest
if ($manifest.task_id -ne $event.task_id -or $manifest.event_id -ne $event.event_id) { throw 'Event and manifest identity mismatch; refusing to wake.' }
if ($manifest.thread_id -ne $event.thread_id) { throw 'Event and manifest thread ID mismatch; refusing to wake.' }
if ((Resolve-AbsolutePath $manifest.done_event_path) -ne (Resolve-AbsolutePath $EventPath)) { throw 'Event path mismatch.' }
if ((Resolve-AbsolutePath $manifest.workspace) -ne (Resolve-AbsolutePath $event.workspace)) { throw 'Workspace mismatch.' }
if ((Resolve-AbsolutePath $manifest.report_path) -ne (Resolve-AbsolutePath $event.report_path)) { throw 'Report path mismatch.' }
if ([string]::IsNullOrWhiteSpace([string]$manifest.thread_id)) { throw 'Thread ID is empty; refusing to infer one.' }

$reportState = Get-ReportState $event.report_path
if ($event.status -eq 'complete' -and -not $reportState.valid) { throw "Complete event has no published report: $($reportState.reason)" }

$delays = @(0, 1, 3, 8)
$wakeSucceeded = $false
$lastError = $null
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $proc = $null
    try {
        if ($attempt -gt 1) { Start-Sleep -Seconds $delays[[Math]::Min($attempt - 1, $delays.Count - 1)] }
        $app = $manifest.app_server
        $environment = @{ CODEX_HOME = [string]$app.codex_home }
        $proc = Start-ArgumentListProcess -FilePath ([string]$app.executable) -Arguments @($app.arguments) -Environment $environment -RedirectInput -RedirectOutput -RedirectError
        Send-JsonLine $proc ([ordered]@{ method = 'initialize'; id = 1; params = [ordered]@{ clientInfo = [ordered]@{ name = 'external-agent-event-handoff'; title = 'External Agent Event Handoff'; version = '1.0.0' } } })
        $init = Read-Response $proc 1
        if ($init.PSObject.Properties.Name -contains 'error' -and $init.error) { throw "initialize failed: $($init.error.message)" }
        Send-JsonLine $proc ([ordered]@{ method = 'initialized'; params = [ordered]@{} })
        Send-JsonLine $proc ([ordered]@{ method = 'thread/resume'; id = 2; params = [ordered]@{ threadId = [string]$manifest.thread_id; excludeTurns = $true } })
        $resume = Read-Response $proc 2
        if ($resume.PSObject.Properties.Name -contains 'error' -and $resume.error) { throw "thread/resume failed: $($resume.error.message)" }
        $thread = $resume.result.thread
        if (-not $thread -or $thread.id -ne $manifest.thread_id) { throw 'thread/resume returned a different or empty thread ID.' }
        if ($thread.status.type -eq 'active') { throw 'Target thread is active; refusing to create a duplicate turn.' }
        if ($thread.status.type -notin @('idle','notLoaded')) { throw "Target thread status is not safely resumable: $($thread.status.type)" }
        if ($thread.canAcceptDirectInput -ne $true) { throw 'Target thread does not explicitly advertise direct input.' }

        $text = "External agent task $($event.task_id) completed. Event: $($EventPath). Report: $($event.report_path). Use `$external-agent-event-handoff collect. Validate the event once, then inspect the report and scoped diff. Do not modify or commit."
        $turnParams = [ordered]@{ threadId = [string]$manifest.thread_id; input = @([ordered]@{ type = 'text'; text = $text }) }
        if ($app.wake_model) { $turnParams.model = [string]$app.wake_model }
        Send-JsonLine $proc ([ordered]@{ method = 'turn/start'; id = 3; params = $turnParams })
        $turn = Read-Response $proc 3
        if ($turn.PSObject.Properties.Name -contains 'error' -and $turn.error) { throw "turn/start failed: $($turn.error.message)" }
        if (-not $turn.result.turn.id) { throw 'turn/start returned no turn ID.' }
        Set-EventWakeState $event 'sent'
        $wakeSucceeded = $true
        Write-Output "wake sent: event=$($event.event_id) thread=$($manifest.thread_id) turn=$($turn.result.turn.id)"
        break
    } catch {
        $lastError = $_.Exception.Message
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } } }
        if ($attempt -eq $MaxAttempts) { break }
    } finally {
        if ($proc) { try { $proc.StandardInput.Close() } catch { }; try { $proc.Dispose() } catch { } }
    }
}
if (-not $wakeSucceeded) {
    Set-EventWakeState $event 'failed'
    Notify-Pending $event
    Write-Error "Wake failed after $MaxAttempts attempt(s): $lastError"
    exit 3
}
