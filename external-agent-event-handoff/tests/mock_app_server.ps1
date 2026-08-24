param([Parameter(Mandatory)][string]$LogPath,[string]$ReturnThreadId,[string[]]$LoadedThreadIds=@())
Set-StrictMode -Version Latest
$logParent = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
if (-not $ReturnThreadId) { $ReturnThreadId = '' }
function Emit($value) {
    $line = $value | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    [Console]::Out.WriteLine($line); [Console]::Out.Flush()
}
$experimentalApi = $false
while ($line = [Console]::In.ReadLine()) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $request = $line | ConvertFrom-Json
    if ($request.id) { Add-Content -LiteralPath $LogPath -Value ("REQUEST " + $line) -Encoding utf8 }
    switch ([string]$request.method) {
        'initialize' {
            if (($request.params.PSObject.Properties.Name -contains 'capabilities') -and $request.params.capabilities -and ($request.params.capabilities.PSObject.Properties.Name -contains 'experimentalApi')) {
                $experimentalApi = [bool]$request.params.capabilities.experimentalApi
            }
            Emit ([ordered]@{ method = 'server/ready'; params = [ordered]@{ state = 'initialized' } })
            Emit ([ordered]@{ id = $request.id; result = [ordered]@{ userAgent = 'mock-app-server'; codexHome = 'mock'; platformFamily = 'windows'; platformOs = 'windows' } })
        }
        'initialized' { }
        'thread/loaded/list' {
            Emit ([ordered]@{ id = $request.id; result = [ordered]@{ data = @($LoadedThreadIds) } })
        }
        'thread/resume' {
            Emit ([ordered]@{ id = $request.id; error = [ordered]@{ code = -32000; message = 'thread already has an active writer' } })
        }
        'thread/queue/add' {
            if (-not $experimentalApi) {
                Emit ([ordered]@{ id = $request.id; error = [ordered]@{ code = -32602; message = 'thread/queue/add requires experimentalApi capability' } })
                continue
            }
            if ($ReturnThreadId -and [string]$request.params.threadId -ne $ReturnThreadId) {
                Emit ([ordered]@{ id = $request.id; error = [ordered]@{ code = -32602; message = 'thread not found' } })
                continue
            }
            Emit ([ordered]@{ id = $request.id; result = [ordered]@{ queuedSubmission = [ordered]@{ id = 'mock-queue-1'; clientUserMessageId = [string]$request.params.clientUserMessageId; input = @($request.params.input) } } })
        }
        'thread/queue/start' {
            Emit ([ordered]@{ id = $request.id; result = [ordered]@{ turn = [ordered]@{ id = 'mock-turn-1'; status = 'inProgress'; items = @() } } })
            break
        }
    }
}
