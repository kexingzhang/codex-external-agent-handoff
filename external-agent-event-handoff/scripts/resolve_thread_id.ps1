param(
    [string]$AppServerExecutable,
    [string[]]$AppServerArgument = @(),
    [string]$CodexHome,
    [switch]$PreferAppServer
)
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$source = $null
$threadId = $null
$candidates = @()
if (-not $PreferAppServer) {
    $threadId = Get-ThreadIdFromEnvironment
    if ($threadId) {
        $source = 'environment'
        $candidates = @($threadId)
    }
}
if (-not $threadId) {
    try {
        $candidates = @(Get-ThreadCandidatesFromAppServer -Executable $AppServerExecutable -Arguments $AppServerArgument -CodexHome $CodexHome)
        $source = 'app-server'
        if ($candidates.Count -eq 1) { $threadId = [string]$candidates[0] }
    } catch {
        $source = 'app-server-error'
        Write-Warning "Thread discovery through App Server failed: $($_.Exception.Message)"
    }
}
$result = [ordered]@{
    source = $source
    thread_id = $threadId
    candidates = @($candidates)
    status = if ($threadId) { 'single' } elseif ($candidates.Count -gt 1) { 'multiple' } else { 'none' }
    note = if ($threadId) { 'Confirm this exact thread ID before dispatch.' } elseif ($candidates.Count -gt 1) { 'Multiple windows found; select the intended thread for dispatch.' } else { 'No current thread could be resolved without guessing.' }
}
$result | ConvertTo-Json -Depth 20