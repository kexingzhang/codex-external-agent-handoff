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
