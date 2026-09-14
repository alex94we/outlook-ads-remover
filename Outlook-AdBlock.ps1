#Requires -Version 5.1
<#
    Outlook-AdBlock.ps1 - v2.0

    Elimina le pubblicita dalla nuova app Outlook per Windows (olk.exe).

    COME FUNZIONA
      1. Installa OutlookAdFix.dll in C:\Windows\System32 e la registra come
         "verifier DLL" in Image File Execution Options per olk.exe. La DLL viene
         caricata dentro olk.exe a ogni avvio.
      2. La DLL aggancia CreateCoreWebView2EnvironmentWithOptions e i vtable degli
         handler WebView2, quindi inietta un payload JavaScript/CSS in tutte le
         pagine dell'app (outlook.office.com).
      3. Il payload (%LOCALAPPDATA%\Remove-OutlookAds\inject.js) nasconde le righe
         pubblicitarie dell'elenco messaggi.

    Nessun file dell'applicazione viene modificato: tutto passa da una DLL
    caricata nel processo e da un payload aggiornabile senza ricompilare.

    USO
        Avvia-Outlook-AdBlock.cmd  ............ menu con privilegi di amministratore
        .\Outlook-AdBlock.ps1 -Azione Installa
        .\Outlook-AdBlock.ps1 -Azione Rimuovi
        .\Outlook-AdBlock.ps1 -Azione Stato

    File ASCII-only: Windows PowerShell 5.1 lo legge correttamente senza BOM.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Installa', 'Rimuovi', 'Stato')]
    [string]$Azione = 'Menu'
)

$ErrorActionPreference = 'Stop'

$Script:Versione      = '2.0'
$Script:Cartella      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Script:DllNome       = 'OutlookAdFix.dll'
$Script:DllSorgente   = Join-Path $Script:Cartella $Script:DllNome
$Script:InjectSorgente = Join-Path $Script:Cartella 'inject.js'
$Script:DllSistema    = Join-Path $env:windir ('System32\' + $Script:DllNome)
$Script:DirDati       = Join-Path $env:LOCALAPPDATA 'Remove-OutlookAds'
$Script:Inject        = Join-Path $Script:DirDati 'inject.js'
$Script:LogFile       = Join-Path $Script:DirDati 'adfix.log'
$Script:StatoFile     = Join-Path $Script:DirDati 'stato.json'
$Script:Ifeo          = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\olk.exe'
$Script:Aumid         = 'Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows'
$Script:VecchioPatcher = 'C:\Windows\System32\NewOutlookPatcher.dll'

# ------------------------------------------------------------------ output
function Titolo { param([string]$T) Write-Host ''; Write-Host ('  === ' + $T + ' ===') -ForegroundColor Cyan; Write-Host '' }
function Say  { param([string]$T = '', [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }
function Ok   { param([string]$T) Write-Host ('  [ OK ]   ' + $T) -ForegroundColor Green }
function Warn { param([string]$T) Write-Host ('  [AVVISO] ' + $T) -ForegroundColor Yellow }
function Err  { param([string]$T) Write-Host ('  [ERRORE] ' + $T) -ForegroundColor Red }
function Info { param([string]$T) Write-Host ('  [info]   ' + $T) -ForegroundColor DarkCyan }
function Pausa { Write-Host ''; [void](Read-Host '  Premi INVIO per continuare') }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Stato {
    if (Test-Path -LiteralPath $Script:StatoFile) {
        try { return (Get-Content -LiteralPath $Script:StatoFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Save-Stato {
    param($Valore)
    if (-not (Test-Path -LiteralPath $Script:DirDati)) { [void](New-Item -ItemType Directory -Path $Script:DirDati -Force) }
    [System.IO.File]::WriteAllText($Script:StatoFile, ($Valore | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-VersioneOutlook {
    try {
        $p = Get-AppxPackage -Name 'Microsoft.OutlookForWindows' -ErrorAction Stop | Select-Object -First 1
        if ($p) { return $p.Version.ToString() }
    } catch { }
    return $null
}

function Close-Outlook {
    $proc = @(Get-Process -Name 'olk' -ErrorAction SilentlyContinue)
    if ($proc.Count -gt 0) {
        Info 'chiusura di Outlook...'
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
    }
}

function Start-Outlook {
    Info 'avvio di Outlook...'
    try { Start-Process ('shell:AppsFolder\' + $Script:Aumid) }
    catch { Warn 'non sono riuscito ad avviare Outlook: aprilo manualmente.' }
}

function Get-UltimoLog {
    if (-not (Test-Path -LiteralPath $Script:LogFile)) { return @() }
    # il log e' scritto in UTF-16LE dalla DLL
    return @(Get-Content -LiteralPath $Script:LogFile -Tail 20 -Encoding Unicode -ErrorAction SilentlyContinue)
}

function Show-Verifica {
    Titolo 'Verifica'
    Info 'attendo l avvio di Outlook e il caricamento della posta (40 secondi)...'
    Start-Sleep -Seconds 40
    $righe = Get-UltimoLog
    if ($righe.Count -eq 0) {
        Warn 'la DLL non ha scritto il log: potrebbe non essere stata caricata.'
        Info ('percorso atteso: ' + $Script:LogFile)
        return
    }
    if (@($righe | Where-Object { $_ -match 'agganciata' }).Count -gt 0) { Ok 'hook WebView2 installato nella app.' }
    else { Warn 'hook WebView2 non installato: riavvia Outlook e riprova.' }

    if (@($righe | Where-Object { $_ -match 'ExecuteScript OK' }).Count -gt 0) { Ok 'payload iniettato nella pagina.' }
    else { Warn 'payload non iniettato: controlla il log.' }

    Say ''
    Info 'ultime righe del log:'
    $righe | Select-Object -Last 8 | ForEach-Object { Say ('    ' + $_) 'DarkGray' }
    Say ''
    Info 'Apri Outlook, vai nella scheda "Altra" dell elenco messaggi: gli annunci non devono piu comparire.'
}

# ------------------------------------------------------------------ azioni
function Invoke-Installa {
    Titolo 'Installazione di Outlook-AdBlock'
    if (-not (Test-Path -LiteralPath $Script:DllSorgente)) {
        Err ('manca ' + $Script:DllNome + ' accanto allo script.')
        Info 'compilala con:  build\build.cmd   (richiede Visual Studio 2022 Build Tools, carico C++)'
        Info 'oppure scarica OutlookAdFix.dll dagli artefatti di GitHub Actions / dalle Releases.'
        return
    }
    if (-not (Test-Path -LiteralPath $Script:InjectSorgente)) { Err ('file mancante: ' + $Script:InjectSorgente); return }
    if (-not (Test-Admin)) {
        Err 'servono i privilegi di amministratore.'
        Info 'avvia Avvia-Outlook-AdBlock.cmd (chiede i privilegi da solo).'
        return
    }

    if (-not (Test-Path -LiteralPath $Script:DirDati)) { [void](New-Item -ItemType Directory -Path $Script:DirDati -Force) }
    Copy-Item -LiteralPath $Script:InjectSorgente -Destination $Script:Inject -Force
    Ok ('payload aggiornato in ' + $Script:Inject)

    Close-Outlook

    Copy-Item -LiteralPath $Script:DllSorgente -Destination $Script:DllSistema -Force
    Ok ('DLL installata in ' + $Script:DllSistema)

    $prec = ''
    if (Test-Path -LiteralPath $Script:Ifeo) {
        $prec = [string](Get-ItemProperty -Path $Script:Ifeo -Name 'VerifierDlls' -ErrorAction SilentlyContinue).VerifierDlls
    }
    Save-Stato ([pscustomobject]@{
        versione           = $Script:Versione
        data               = (Get-Date).ToString('s')
        verifierPrecedente = $prec
    })
    if (-not [string]::IsNullOrWhiteSpace($prec)) { Info ('VerifierDlls precedente: ' + $prec) }

    if (-not (Test-Path -LiteralPath $Script:Ifeo)) { [void](New-Item -Path $Script:Ifeo -Force) }
    Set-ItemProperty -Path $Script:Ifeo -Name 'VerifierDlls' -Value $Script:DllNome
    Set-ItemProperty -Path $Script:Ifeo -Name 'GlobalFlag' -Value 256 -Type DWord
    Ok 'registrazione in Image File Execution Options completata'

    $pol = 'HKCU:\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments'
    if (Test-Path -LiteralPath $pol) {
        Remove-Item -Path $pol -Recurse -Force -ErrorAction SilentlyContinue
        Ok 'rimossa la chiave di criterio WebView2 (non piu necessaria)'
    }
    if (Test-Path -LiteralPath $Script:VecchioPatcher) {
        Info 'il vecchio NewOutlookPatcher.dll non viene piu usato (resta su disco, puoi disinstallarlo dal suo programma).'
    }

    Remove-Item -LiteralPath $Script:LogFile -Force -ErrorAction SilentlyContinue
    Start-Outlook
    Show-Verifica
}

function Invoke-Rimuovi {
    Titolo 'Rimozione di Outlook-AdBlock'
    if (-not (Test-Admin)) {
        Err 'servono i privilegi di amministratore.'
        Info 'avvia Avvia-Outlook-AdBlock.cmd (chiede i privilegi da solo).'
        return
    }
    Close-Outlook

    $stato = Get-Stato
    if (Test-Path -LiteralPath $Script:Ifeo) {
        $prec = ''
        if ($null -ne $stato) { $prec = [string]$stato.verifierPrecedente }
        if ([string]::IsNullOrWhiteSpace($prec)) {
            Remove-ItemProperty -Path $Script:Ifeo -Name 'VerifierDlls' -ErrorAction SilentlyContinue
            $props = @((Get-Item -Path $Script:Ifeo).Property)
            if ($props.Count -le 1) { Remove-Item -Path $Script:Ifeo -Recurse -Force -ErrorAction SilentlyContinue }
            Ok 'registrazione rimossa.'
        } else {
            Set-ItemProperty -Path $Script:Ifeo -Name 'VerifierDlls' -Value $prec
            Ok ('VerifierDlls ripristinato a: ' + $prec)
        }
    }

    if (Test-Path -LiteralPath $Script:DllSistema) {
        try { Remove-Item -LiteralPath $Script:DllSistema -Force; Ok 'DLL rimossa da System32.' }
        catch { Warn ('non sono riuscito a rimuovere la DLL: ' + $_.Exception.Message) }
    }
    if (Test-Path -LiteralPath $Script:Inject) { Remove-Item -LiteralPath $Script:Inject -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Script:LogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:StatoFile -Force -ErrorAction SilentlyContinue
    Ok 'file del payload rimossi.'

    Start-Outlook
}

function Show-Stato {
    Titolo 'Stato attuale'
    $ver = Get-VersioneOutlook
    if ($ver) { Ok ('app Outlook per Windows: versione ' + $ver) } else { Warn 'app Outlook per Windows non rilevata.' }
    if (Test-Admin) { Ok 'sessione con privilegi di amministratore.' } else { Warn 'sessione senza privilegi di amministratore.' }

    Say ''
    Say ('  Registrazione (' + $Script:Ifeo + ')') 'White'
    if (Test-Path -LiteralPath $Script:Ifeo) {
        $v = [string](Get-ItemProperty -Path $Script:Ifeo -Name 'VerifierDlls' -ErrorAction SilentlyContinue).VerifierDlls
        $g = (Get-ItemProperty -Path $Script:Ifeo -Name 'GlobalFlag' -ErrorAction SilentlyContinue).GlobalFlag
        if ($v -eq $Script:DllNome) { Ok ('VerifierDlls = ' + $v) } elseif ($v) { Warn ('VerifierDlls = ' + $v + ' (non e la nostra DLL)') } else { Warn 'VerifierDlls assente' }
        Say ('    GlobalFlag = ' + $g)
    } else { Warn 'chiave di registro assente: Outlook-AdBlock non e installato.' }

    Say ''
    Say '  File' 'White'
    if (Test-Path -LiteralPath $Script:DllSistema) { Ok ('DLL presente: ' + $Script:DllSistema) } else { Warn 'DLL assente in System32' }
    if (Test-Path -LiteralPath $Script:Inject) { Ok ('payload presente: ' + $Script:Inject) } else { Warn 'payload assente' }

    Say ''
    Say '  Ultimo avvio di Outlook' 'White'
    $righe = Get-UltimoLog
    if ($righe.Count -eq 0) { Warn 'nessun log disponibile' }
    else {
        if (@($righe | Where-Object { $_ -match 'agganciata' }).Count -gt 0) { Ok 'hook WebView2 attivo' } else { Warn 'hook WebView2 non registrato nel log' }
        if (@($righe | Where-Object { $_ -match 'ExecuteScript OK' }).Count -gt 0) { Ok 'payload iniettato' } else { Warn 'payload non iniettato' }
        $righe | Select-Object -Last 5 | ForEach-Object { Say ('    ' + $_) 'DarkGray' }
    }
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ==============================================================' -ForegroundColor DarkCyan
        Write-Host '    Outlook-AdBlock - pubblicita rimosse dalla app Outlook'      -ForegroundColor Cyan
        Write-Host '  ==============================================================' -ForegroundColor DarkCyan
        $ver = Get-VersioneOutlook
        if ($ver) { Write-Host ('    Versione app Outlook : ' + $ver) }
        if (Test-Admin) { Write-Host '    Privilegi admin     : si' -ForegroundColor Green }
        else { Write-Host '    Privilegi admin     : no' -ForegroundColor Yellow }
        Write-Host '  --------------------------------------------------------------'
        Write-Host '    [1] Installa Outlook-AdBlock'
        Write-Host '    [2] Rimuovi Outlook-AdBlock'
        Write-Host '    [3] Stato e verifica'
        Write-Host '    [0] Esci'
        Write-Host '  --------------------------------------------------------------'
        $scelta = Read-Host '    Scelta'
        switch ($scelta) {
            '1' { Invoke-Installa; Pausa }
            '2' { Invoke-Rimuovi;  Pausa }
            '3' { Show-Stato;      Pausa }
            '0' { return }
            default { }
        }
    }
}

switch ($Azione) {
    'Installa' { Invoke-Installa }
    'Rimuovi'  { Invoke-Rimuovi }
    'Stato'    { Show-Stato }
    default    { Show-Menu }
}
