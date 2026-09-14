# Scarica l'SDK WebView2 (header WebView2.h) usato per compilare OutlookAdFix.dll
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest = Join-Path $PSScriptRoot 'sdk'
$include = Join-Path $dest 'include'
New-Item -ItemType Directory -Path $include -Force | Out-Null

if (Test-Path (Join-Path $include 'WebView2.h')) {
    Write-Host 'SDK WebView2 gia presente.'
    exit 0
}

Write-Host 'Scarico l''SDK WebView2 da nuget.org...'
$idx = Invoke-RestMethod -Uri 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json' -TimeoutSec 30
$stabili = @($idx.versions | Where-Object { $_ -notmatch 'prerelease' })
$ver = if ($stabili.Count -gt 0) { $stabili[-1] } else { $idx.versions[-1] }
Write-Host ('versione: ' + $ver)

$nupkg = Join-Path $dest 'webview2.zip'
Invoke-WebRequest -Uri ('https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/' + $ver + '/microsoft.web.webview2.' + $ver + '.nupkg') -OutFile $nupkg -TimeoutSec 180

$tmp = Join-Path $dest 'pkg'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -LiteralPath $nupkg -DestinationPath $tmp -Force

Copy-Item (Join-Path $tmp 'build\native\include\*.h') $include -Force
Remove-Item $tmp -Recurse -Force
Remove-Item $nupkg -Force

if (Test-Path (Join-Path $include 'WebView2.h')) { Write-Host ('SDK pronto in ' + $include) }
else { Write-Error 'WebView2.h non trovato nel pacchetto scaricato.' }
