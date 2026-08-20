param([Parameter(Mandatory)][string]$LogPath,[string]$ReturnThreadId)
Set-StrictMode -Version Latest
$logParent = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
if (-not $ReturnThreadId) { $ReturnThreadId = '' }
function Emit($value) {
    $line = $value | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    [Console]::Out.WriteLine($line); [Console]::Out.Flush()
}
while ($line = [Console]::In.ReadLine()) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $request = $line | ConvertFrom-Json
    if ($request.id) { Add-Content -LiteralPath $LogPath -Value ("REQUEST " + $line) -Encoding utf8 }
    switch ([string]$request.method) {
        'initialize' { Emit ([ordered]@{ id = $request.id; result = [ordered]@{ userAgent = 'mock-app-server'; codexHome = 'mock'; platformFamily = 'windows'; platformOs = 'windows' } }) }
        'initialized' { }
        'thread/resume' {
            $id = if ($ReturnThreadId) { $ReturnThreadId } else { [string]$request.params.threadId }
            Emit ([ordered]@{ id = $request.id; result = [ordered]@{ thread = [ordered]@{ id = $id; status = [ordered]@{ type = 'idle' }; canAcceptDirectInput = $true } } })
        }
        'turn/start' {
            Emit ([ordered]@{ id = $request.id; result = [ordered]@{ turn = [ordered]@{ id = 'mock-turn-1'; status = 'inProgress' } } })
            Emit ([ordered]@{ method = 'turn/completed'; params = [ordered]@{ turn = [ordered]@{ id = 'mock-turn-1'; status = 'completed' } } })
            break
        }
    }
}
