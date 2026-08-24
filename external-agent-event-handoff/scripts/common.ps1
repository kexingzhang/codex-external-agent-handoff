Set-StrictMode -Version Latest

function Resolve-AbsolutePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$MustExist)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path must not be empty.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) { throw "Path does not exist: $full" }
    return $full
}

function Test-PathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $child = (Resolve-AbsolutePath $Path).TrimEnd('\') + '\'
    $root = (Resolve-AbsolutePath $Parent).TrimEnd('\') + '\'
    return $child.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Write-AtomicText {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text = '', [switch]$NoOverwrite)
    $full = Resolve-AbsolutePath $Path
    Ensure-Directory (Split-Path -Parent $full)
    $tmp = "$full.tmp.$([guid]::NewGuid().ToString('N'))"
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($Text)
    $stream = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    try {
        if ($NoOverwrite -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $tmp -Force; return $false }
        if ($NoOverwrite) {
            Move-Item -LiteralPath $tmp -Destination $full
        } elseif (Test-Path -LiteralPath $full) {
            [IO.File]::Move($tmp, $full, $true)
        } else {
            Move-Item -LiteralPath $tmp -Destination $full
        }
        return $true
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if ($NoOverwrite -and (Test-Path -LiteralPath $full)) { return $false }
        throw
    }
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [switch]$NoOverwrite)
    $json = $Value | ConvertTo-Json -Depth 40
    return Write-AtomicText -Path $Path -Text $json -NoOverwrite:$NoOverwrite
}

function Read-JsonFile([string]$Path) {
    $full = Resolve-AbsolutePath $Path -MustExist
    return Get-Content -LiteralPath $full -Raw | ConvertFrom-Json
}

function New-OpaqueId { return [guid]::NewGuid().ToString('N') }
function Get-NowUtc { return [DateTime]::UtcNow.ToString('o') }

function Get-GitExecutable {
    foreach ($name in @('git.exe', 'git')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    return $null
}

function Get-GitBaseCommit([string]$Workspace) {
    try {
        $git = Get-GitExecutable
        if (-not $git) { return $null }
        $value = & $git -c "safe.directory=$Workspace" -C $Workspace rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $value) { return ([string]$value).Trim() }
    } catch { }
    return $null
}

function Get-GitChangedFiles([string]$Workspace) {
    try {
        $git = Get-GitExecutable
        if (-not $git) { return @() }
        $lines = @(& $git -c "safe.directory=$Workspace" -C $Workspace status --short 2>$null)
        if ($LASTEXITCODE -eq 0) { return @($lines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
    } catch { }
    return @()
}

function Get-PowerShellPath {
    $candidate = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'No PowerShell executable is available.'
}

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
        $messageProperties = @($message.PSObject.Properties.Name)
        if (($messageProperties -contains 'id') -and $null -ne $message.id -and [int]$message.id -eq $Id) { return $message }
    }
    throw "Timed out waiting for App Server response id=$Id."
}

function Get-ThreadIdFromEnvironment {
    # Codex Desktop runs expose the current window/thread ID directly. This is the
    # preferred source because it does not require App Server discovery.
    foreach ($name in @('CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'CODEX_ACTIVE_THREAD_ID')) {
        $value = [string]([Environment]::GetEnvironmentVariable($name))
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

function Get-ThreadCandidatesFromAppServer {
    param([Parameter(Mandatory)][string]$Executable, [string[]]$Arguments = @(), [string]$CodexHome)
    # Thread discovery is read-only. The server is consulted only when an explicit
    # environment source is unavailable or when a candidate must be validated.
    $environment = @{}
    if ($CodexHome) { $environment.CODEX_HOME = $CodexHome }
    $proc = $null
    try {
        $effectiveArguments = if ($null -eq $Arguments) { @() } else { @($Arguments) }
        $proc = Start-ArgumentListProcess -FilePath $Executable -Arguments $effectiveArguments -Environment $environment -RedirectInput -RedirectOutput -RedirectError
        Send-JsonLine $proc ([ordered]@{ method = 'initialize'; id = 1; params = [ordered]@{ clientInfo = [ordered]@{ name = 'external-agent-event-handoff'; title = 'External Agent Event Handoff'; version = '1.0.0' }; capabilities = [ordered]@{ experimentalApi = $true } } })
        $init = Read-Response $proc 1 10
        if ($init.PSObject.Properties.Name -contains 'error' -and $init.error) { throw "initialize failed: $($init.error.message)" }
        Send-JsonLine $proc ([ordered]@{ method = 'initialized'; params = [ordered]@{} })
        # Ask only for loaded sessions first; they are the current interactive windows.
        Send-JsonLine $proc ([ordered]@{ method = 'thread/loaded/list'; id = 2; params = [ordered]@{} })
        $loaded = Read-Response $proc 2 10
        if ($loaded.PSObject.Properties.Name -contains 'error' -and $loaded.error) { throw "thread/loaded/list failed: $($loaded.error.message)" }
        if ($loaded.result -and $null -ne $loaded.result.data) { return @($loaded.result.data | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        Send-JsonLine $proc ([ordered]@{ method = 'thread/list'; id = 2; params = [ordered]@{ limit = 20; sortKey = 'recency_at'; sortDirection = 'desc' } })
        $list = Read-Response $proc 2 10
        if ($list.PSObject.Properties.Name -contains 'error' -and $list.error) { throw "thread/list failed: $($list.error.message)" }
        if ($list.result -and $null -ne $list.result.data) {
            return @($list.result.data | ForEach-Object { if ($_.id) { [string]$_.id } } | Where-Object { $_ })
        }
        return @()
    } finally {
        if ($proc) { try { $proc.StandardInput.Close() } catch { }; try { $proc.Dispose() } catch { } }
    }
}

function Get-ThreadSummary {
    param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$ThreadId, [string[]]$Arguments, [string]$CodexHome)
    # Read-only metadata lookup: title/name plus the first user message preview.
    $environment = @{}
    if ($CodexHome) { $environment.CODEX_HOME = $CodexHome }
    $proc = $null
    try {
        $effectiveArguments = if ($null -eq $Arguments) { @() } else { @($Arguments) }
        $proc = Start-ArgumentListProcess -FilePath $Executable -Arguments $effectiveArguments -Environment $environment -RedirectInput -RedirectOutput -RedirectError
        Send-JsonLine $proc ([ordered]@{ method = 'initialize'; id = 1; params = [ordered]@{ clientInfo = [ordered]@{ name = 'external-agent-event-handoff'; title = 'External Agent Event Handoff'; version = '1.0.0' }; capabilities = [ordered]@{ experimentalApi = $true } } })
        $init = Read-Response $proc 1 10
        if ($init.PSObject.Properties.Name -contains 'error' -and $init.error) { throw "initialize failed: $($init.error.message)" }
        Send-JsonLine $proc ([ordered]@{ method = 'initialized'; params = [ordered]@{} })
        Send-JsonLine $proc ([ordered]@{ method = 'thread/read'; id = 2; params = [ordered]@{ threadId = $ThreadId } })
        $read = Read-Response $proc 2 10
        if ($read.PSObject.Properties.Name -contains 'error' -and $read.error) { throw "thread/read failed: $($read.error.message)" }
        $thread = $read.result.thread
        if (-not $thread -or -not $thread.id) { throw "thread/read returned no thread data for $ThreadId" }
        $name = if ($thread.name) { [string]$thread.name } elseif ($thread.PSObject.Properties.Name -contains 'title' -and $thread.title) { [string]$thread.title } else { '' }
        $preview = if ($thread.preview) { [string]$thread.preview } else { '' }
        return [pscustomobject]@{ id = [string]$thread.id; name = $name; preview = $preview }
    } finally {
        if ($proc) { try { $proc.StandardInput.Close() } catch { }; try { $proc.Dispose() } catch { } }
    }
}

function Assert-NoCredentialLiterals([string[]]$Arguments) {
    foreach ($arg in @($Arguments)) {
        if ([string]$arg -match '(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|bearer)\s*[:=]') {
            throw 'Credential-looking literals are not accepted in command arguments; use the provider or Codex CLI authentication environment.'
        }
    }
}

function Start-ArgumentListProcess {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment, [switch]$RedirectInput, [switch]$RedirectOutput, [switch]$RedirectError)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $RedirectInput
    $psi.RedirectStandardOutput = $RedirectOutput
    $psi.RedirectStandardError = $RedirectError
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add([string]$arg) }
    if ($Environment) { foreach ($entry in $Environment.GetEnumerator()) { $psi.Environment[$entry.Key] = [string]$entry.Value } }
    $proc = [Diagnostics.Process]::new(); $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "Failed to start process: $FilePath" }
    return $proc
}

function Assert-ManifestShape($Manifest) {
    foreach ($name in @('schema_version','task_id','event_id','provider','thread_id','workspace','report_path','done_event_path','manifest_path','state_path')) {
        if (-not $Manifest.$name) { throw "Manifest missing $name." }
    }
    if ($Manifest.schema_version -ne 'external-agent-event/v1') { throw "Unsupported manifest schema: $($Manifest.schema_version)" }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.thread_id)) { throw 'Manifest thread_id is empty; refusing to infer one.' }
}

function Assert-EventShape($Event) {
    foreach ($name in @('schema_version','task_id','event_id','status','provider','thread_id','workspace','report_path','manifest_path','wake_state')) {
        if ($null -eq $Event.$name -or [string]::IsNullOrWhiteSpace([string]$Event.$name)) { throw "Event missing $name." }
    }
    if ($Event.schema_version -ne 'external-agent-event/v1') { throw "Unsupported event schema: $($Event.schema_version)" }
    if ($Event.status -notin @('complete','failed','timed_out')) { throw "Unsupported event status: $($Event.status)" }
    if ($Event.wake_state -notin @('pending','sent','failed')) { throw "Unsupported wake state: $($Event.wake_state)" }
}

function Get-ReportState([string]$ReportPath) {
    $full = Resolve-AbsolutePath $ReportPath
    $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer -and $item.Extension -eq '.tmp') { return [pscustomobject]@{ exists = $false; valid = $false; reason = 'report is still a .tmp file' } }
    if (-not $item -or $item.PSIsContainer) { return [pscustomobject]@{ exists = $false; valid = $false; reason = 'report is missing or not a file' } }
    return [pscustomobject]@{ exists = $true; valid = $true; reason = $null }
}
