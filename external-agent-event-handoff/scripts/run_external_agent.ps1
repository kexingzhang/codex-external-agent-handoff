param([Parameter(Mandatory)][string]$ManifestPath)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$manifest = Read-JsonFile $ManifestPath
Assert-ManifestShape $manifest
if ((Resolve-AbsolutePath $manifest.manifest_path) -ne (Resolve-AbsolutePath $ManifestPath)) { throw 'Manifest path mismatch.' }
$workspace = Resolve-AbsolutePath $manifest.workspace -MustExist
$report = Resolve-AbsolutePath $manifest.report_path
$eventPath = Resolve-AbsolutePath $manifest.done_event_path
$startedAt = Get-NowUtc
$providerPid = 0
$exitCode = $null
$status = 'failed'
$reason = $null
$stdoutPath = Join-Path $manifest.task_directory "$($manifest.task_id).provider.stdout.log"
$stderrPath = Join-Path $manifest.task_directory "$($manifest.task_id).provider.stderr.log"

try {
    $command = $manifest.provider_command
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [string]$command.executable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $workspace
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in @($command.arguments)) { [void]$psi.ArgumentList.Add([string]$arg) }
    $proc = [Diagnostics.Process]::new(); $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "Provider process failed to start: $($command.executable)" }
    $providerPid = $proc.Id
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit([int]$manifest.timeout_seconds * 1000)
    if (-not $finished) {
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        $proc.WaitForExit()
        $status = 'timed_out'
        $reason = "provider exceeded timeout_seconds=$($manifest.timeout_seconds)"
    } else {
        $exitCode = $proc.ExitCode
        $reportState = Get-ReportState $report
        if ($reportState.valid) {
            if ($exitCode -eq 0) { $status = 'complete' }
            else {
                # Provider finished its deliverable but exited nonzero (e.g., max-turns
                # reached during cleanup). Report exists and is valid, so accept it.
                $status = 'complete'
                $reason = "provider exited with code $exitCode after publishing a valid delivery report"
            }
        } else {
            $status = 'failed'
            if ($exitCode -ne 0) { $reason = "provider exited with code $exitCode; $($reportState.reason)" }
            else { $reason = $reportState.reason }
        }
    }
    Write-AtomicText -Path $stdoutPath -Text $stdoutTask.GetAwaiter().GetResult() | Out-Null
    Write-AtomicText -Path $stderrPath -Text $stderrTask.GetAwaiter().GetResult() | Out-Null
} catch {
    $status = 'failed'
    $reason = $_.Exception.Message
    try { Write-AtomicText -Path $stderrPath -Text $reason | Out-Null } catch { }
}

$event = [ordered]@{
    schema_version = 'external-agent-event/v1'
    task_id = $manifest.task_id
    event_id = $manifest.event_id
    status = $status
    provider = $manifest.provider
    thread_id = $manifest.thread_id
    workspace = $workspace
    base_commit = $manifest.base_commit
    pid = [int]$manifest.pid
    provider_pid = $providerPid
    exit_code = $exitCode
    started_at = $startedAt
    finished_at = Get-NowUtc
    report_path = $report
    changed_files = @(Get-GitChangedFiles $workspace)
    wake_state = 'pending'
    manifest_path = (Resolve-AbsolutePath $manifest.manifest_path)
    reason = $reason
}
if (-not (Write-AtomicJson -Path $eventPath -Value $event -NoOverwrite)) { exit 0 }
Write-AtomicJson -Path $manifest.state_path -Value ([ordered]@{ task_id = $manifest.task_id; event_id = $manifest.event_id; status = $status; wake_state = 'pending'; at = Get-NowUtc; reason = $reason }) | Out-Null

$wake = Join-Path $PSScriptRoot 'wake_codex.ps1'
if ([string]$manifest.app_server.delivery_mode -eq 'wait') { exit 0 }
try {
    & (Get-PowerShellPath) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wake -EventPath $eventPath -MaxAttempts ([int]$manifest.app_server.max_attempts)
    if ($LASTEXITCODE -ne 0) { exit 2 }
} catch {
    Write-Warning "Wake failed: $($_.Exception.Message)"
    exit 2
}
