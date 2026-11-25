<# Local static host for Windows PowerShell. A fixed origin preserves browser storage across launches. #>
[CmdletBinding()]
param([int]$Port = 8061, [switch]$OpenBrowser, [string]$Directory = (Join-Path $PSScriptRoot '../../web_build'))
$ErrorActionPreference = 'Stop'
$directory = (Resolve-Path -LiteralPath $Directory).ProviderPath
if (!(Test-Path -LiteralPath (Join-Path $directory 'index.html') -PathType Leaf)) { throw 'Build the production Web export first.' }
$url = "http://127.0.0.1:$Port/"
Add-Type -Path (Join-Path $PSScriptRoot 'LocalWebHost.cs')
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$listener.ExclusiveAddressUse = $true
try {
    $listener.Start()
} catch {
    $existing = ''
    try { $existing = (New-Object Net.WebClient).DownloadString($url + '_ftoons_health') } catch {}
    if ($existing -eq "ftoons-production $directory") {
        if ($OpenBrowser) { Start-Process $url }
        return
    }
    throw "Could not serve $url. $($_.Exception.GetBaseException().Message)"
}
try {
    Write-Output "Serving ftoons at $url. Keep this window open while playing. Ctrl+C stops the server."
    if ($OpenBrowser) { Start-Process $url }
    while ($true) {
        if ($listener.Pending()) { [Ftoons.LocalWebHost]::Serve($listener.AcceptTcpClient(), $directory) }
        else { Start-Sleep -Milliseconds 50 }
    }
} finally { $listener.Stop() }
