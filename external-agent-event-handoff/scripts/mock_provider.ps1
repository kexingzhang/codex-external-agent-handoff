[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(Mandatory,ParameterSetName='Path')][string]$RequestPath,
    [Parameter(Mandatory,ParameterSetName='Text')][string]$RequestText,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateSet('success','failed','sleep','missing-report','tmp-report')][string]$Mode='success'
)
Set-StrictMode -Version Latest
$request = if ($PSCmdlet.ParameterSetName -eq 'Text') { $RequestText } else { Get-Content -LiteralPath $RequestPath -Raw }
if ($Mode -eq 'sleep') { Start-Sleep -Seconds 2 }
$parent = Split-Path -Parent $ReportPath
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
if ($Mode -ne 'missing-report') {
    $tmp = if ($Mode -eq 'tmp-report') { $ReportPath + '.tmp' } else { $ReportPath + '.tmp' }
    $content = "# Mock delivery`n`nStatus: $Mode`n`nRequest received: $($request.Length) characters.`n"
    [IO.File]::WriteAllText($tmp, $content, [Text.UTF8Encoding]::new($false))
    if ($Mode -ne 'tmp-report') { Move-Item -LiteralPath $tmp -Destination $ReportPath -Force }
}
if ($Mode -eq 'failed') { exit 7 }
exit 0
