Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$skill = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scripts = Join-Path $skill 'scripts'
$pwsh = (Get-Command pwsh.exe).Source
$testRoot = Join-Path $env:TEMP ("external-agent-handoff tests 外部 [" + [guid]::NewGuid().ToString('N') + "]")
$workspace = Join-Path $testRoot 'workspace'
$reports = Join-Path $testRoot 'reports'
New-Item -ItemType Directory -Force -Path $workspace,$reports | Out-Null
$mockServer = Join-Path $PSScriptRoot 'mock_app_server.ps1'
$unavailableServer = Join-Path $PSScriptRoot 'mock_app_server_unavailable.ps1'
$thread = 'thread-test-exact-001'
$log = Join-Path $testRoot 'app-server.log'
$dispatch = Join-Path $scripts 'dispatch_external_agent.ps1'
$wake = Join-Path $scripts 'wake_codex.ps1'
$collect = Join-Path $scripts 'collect_external_agent.ps1'

function Assert($condition, [string]$message) { if (-not $condition) { throw "ASSERTION FAILED: $message" } }
function Wait-ForFile([string]$Path, [int]$Seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) { if (Test-Path -LiteralPath $Path) { return }; Start-Sleep -Milliseconds 100 }
    throw "Timed out waiting for $Path"
}
function Wait-ForEvent([string]$Path, [int]$Seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            try { $event = Get-Content -Raw $Path | ConvertFrom-Json; if ($event.wake_state -ne 'pending') { return $event } } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for completed event $Path"
}
function New-AppArgs([string]$LogPath, [string]$ReturnThreadId = '') {
    $a = @('-NoProfile','-NonInteractive','-File',$mockServer,'-LogPath',$LogPath)
    if ($ReturnThreadId) { $a += @('-ReturnThreadId',$ReturnThreadId) }
    return $a
}
function Dispatch([string]$Mode, [string]$Name, [int]$Timeout = 10, [string]$ServerLog = $log, [string]$ReturnThreadId = '', [string]$AppExe = $pwsh, [string[]]$AppArgs = $null) {
    $report = Join-Path $reports "$Name.md"
    if (-not $AppArgs) { $AppArgs = New-AppArgs $ServerLog $ReturnThreadId }
    $args = @{
        Provider = 'mock'; MockMode = $Mode; Prompt = "test prompt $Name"; Workspace = $workspace; AllowedFile = @('allowed.txt'); ReportPath = $report; ThreadId = $thread; TimeoutSeconds = $Timeout; WakeMaxAttempts = 1; AppServerExecutable = $AppExe; AppServerArgument = $AppArgs
    }
    return (& $dispatch @args | ConvertFrom-Json)
}

$success = Dispatch 'success' 'success'
$successEvent = Wait-ForEvent $success.done_event_path
Assert ($successEvent.status -eq 'complete') 'success status'
Assert ($successEvent.wake_state -eq 'sent') 'success wake sent'
$requestLines = @(Get-Content -LiteralPath $log | Where-Object { $_ -like 'REQUEST *' } | ForEach-Object { ($_ -replace '^REQUEST ','') | ConvertFrom-Json })
Assert (($requestLines.method -join ',') -eq 'initialize,thread/resume,turn/start') 'handshake and turn order'
Assert (@($requestLines | Where-Object method -eq 'turn/start').Count -eq 1) 'one turn/start'
& $wake -EventPath $success.done_event_path | Out-Null
$requestLines2 = @(Get-Content -LiteralPath $log | Where-Object { $_ -like 'REQUEST *' } | ForEach-Object { ($_ -replace '^REQUEST ','') | ConvertFrom-Json })
Assert (@($requestLines2 | Where-Object method -eq 'turn/start').Count -eq 1) 'replay does not start second turn'

$failed = Dispatch 'failed' 'failed'
$failedEvent = Wait-ForEvent $failed.done_event_path
Assert ($failedEvent.status -eq 'failed') 'nonzero provider status'
Assert ($failedEvent.wake_state -eq 'sent') 'failed event wakes once'

$timed = Dispatch 'sleep' 'timed-out' 1
$timedEvent = Wait-ForEvent $timed.done_event_path
Assert ($timedEvent.status -eq 'timed_out') 'timeout status'
Assert ($timedEvent.wake_state -eq 'sent') 'timeout event wakes once'

$missing = Dispatch 'missing-report' 'missing-report'
$missingEvent = Wait-ForEvent $missing.done_event_path
Assert ($missingEvent.status -eq 'failed') 'missing report cannot be complete'

$antigravityReport = Join-Path $reports 'antigravity.md'
$antigravityArgs = @{
    Provider = 'antigravity'; Prompt = 'Antigravity prompt-text expansion test'; Workspace = $workspace; AllowedFile = @(); ReportPath = $antigravityReport; ThreadId = $thread; TimeoutSeconds = 10; WakeMaxAttempts = 1
    ProviderExecutable = $pwsh; ProviderArgument = @('-NoProfile','-NonInteractive','-File',(Join-Path $scripts 'mock_provider.ps1'),'-RequestText','{prompt_text}','-ReportPath','{report_path}','-Mode','success')
    AppServerExecutable = $pwsh; AppServerArgument = (New-AppArgs (Join-Path $testRoot 'antigravity.log'))
}
$antigravity = & $dispatch @antigravityArgs | ConvertFrom-Json
$antigravityEvent = Wait-ForEvent $antigravity.done_event_path
Assert ($antigravityEvent.status -eq 'complete') 'antigravity provider completes'
Assert ($antigravityEvent.provider -eq 'antigravity') 'antigravity provider preserved in event'
$antigravityDelivery = Get-Content -LiteralPath $antigravityReport -Raw
Assert ($antigravityDelivery -like '*Request received:*') 'antigravity prompt text reaches provider'

$mismatchLog = Join-Path $testRoot 'mismatch.log'
$mismatch = Dispatch 'success' 'mismatch' 10 $mismatchLog 'other-thread'
$mismatchEvent = Wait-ForEvent $mismatch.done_event_path
Assert ($mismatchEvent.wake_state -eq 'failed') 'mismatched thread fails closed'

$unavailable = Dispatch 'success' 'unavailable' 10 (Join-Path $testRoot 'unavailable.log') -AppExe $pwsh -AppArgs @('-NoProfile','-NonInteractive','-File',$unavailableServer)
$unavailableEvent = Wait-ForEvent $unavailable.done_event_path
Assert ($unavailableEvent.wake_state -eq 'failed') 'unavailable app server is pending/failed'

$collectOutput = & $collect -EventPath $success.done_event_path | Out-String
Assert ($collectOutput -like '*read-only scoped diff*') 'collect performs read-only inspection'

Write-Output "PASS external-agent-event-handoff tests: $testRoot"
