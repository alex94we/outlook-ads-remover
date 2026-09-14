# Outlook Ads Remover

Removes the advertising rows from the **new Outlook for Windows** app (`olk.exe`).

The ads are no longer fetched from a separate ad domain: the Outlook web UI
(`outlook.office.com`) renders them itself, as a row inside the message list. Blocking domains therefore
does nothing any more. This tool hooks WebView2 **inside** `olk.exe` and injects a small
JavaScript/CSS payload that hides those rows.

> Tested on Outlook for Windows `1.2026.902.100` (WebView2 152, Windows 11, Italian UI).

## How it works

1. `OutlookAdFix.dll` is copied to `C:\Windows\System32` and registered as an Application Verifier
   *verifier DLL* for `olk.exe`:

   ```text
   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\olk.exe
       VerifierDlls = OutlookAdFix.dll
       GlobalFlag   = 0x100
   ```

   Windows then loads the DLL inside every `olk.exe` process, before the app code runs.

2. The DLL hooks `CreateCoreWebView2EnvironmentWithOptions` (IAT of `nh.dll`) and chains the WebView2
   handler vtables (environment handler to environment to controller handler) until it owns the
   `ICoreWebView2` instance.

3. It reads the payload from `%LOCALAPPDATA%\Remove-OutlookAds\inject.js` and injects it with
   `AddScriptToExecuteOnDocumentCreated` and `ExecuteScript`.

4. The payload hides the rows that carry the `iIsOF` class (verified: on the current build that class
   appears **only** on ad rows), with a structural fallback based on the localized ad label
   ("Annuncio", "Advertisement", ...) in case a future Outlook build renames the classes.

No file of the Outlook package is modified, and the payload can be updated without recompiling the DLL.

## Requirements

- Windows 10/11 **x64**
- New Outlook for Windows installed
- **Administrator rights** (System32 + HKLM)
- Optional: Visual Studio 2022 **Build Tools** with the C++ workload, to compile the DLL

## Install

```powershell
git clone https://github.com/alex94we/outlook-ads-remover.git
cd outlook-ads-remover

# 1. build the DLL (downloads the WebView2 SDK automatically)
build\build.cmd

# 2. install (double-click works too)
.\Avvia-Outlook-AdBlock.cmd
```

The launcher asks for elevation and opens a menu:

| Option | Action |
| --- | --- |
| `[1] Installa` | copies the DLL, registers it, updates the payload, restarts Outlook and verifies |
| `[2] Rimuovi` | removes the registration, the DLL and the payload, restores the previous value |
| `[3] Stato` | shows registration, files and the last log lines |

Command line:

```powershell
.\Outlook-AdBlock.ps1 -Azione Installa
.\Outlook-AdBlock.ps1 -Azione Stato
.\Outlook-AdBlock.ps1 -Azione Rimuovi
```

### No compiler?

GitHub Actions builds the DLL on every push: grab `OutlookAdFix.dll` from the **Actions** artifacts
(or from **Releases** if a tag was published) and put it next to `Outlook-AdBlock.ps1`.

## Uninstall

Run the launcher and pick `[2]`, or manually:

1. Close Outlook.
2. Delete the `VerifierDlls` value under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\olk.exe`.
3. Delete `C:\Windows\System32\OutlookAdFix.dll`.
4. Delete `%LOCALAPPDATA%\Remove-OutlookAds`.

## Troubleshooting

The DLL writes a log to `%LOCALAPPDATA%\Remove-OutlookAds\adfix.log`:

```text
=== OutlookAdFix caricata ===
IAT agganciata (CreateCoreWebView2EnvironmentWithOptions)
hook: environment handler agganciato
hook: environment agganciato
hook: controller handler agganciato
iniezione: AddScriptToExecuteOnDocumentCreated OK
iniezione: ExecuteScript OK
```

- **Ads are still there**: check the log. If the hook lines are missing, restart Outlook.
- **Outlook does not start** (exit code 0xC0000142): the verifier value points to a broken DLL.
  Remove the `VerifierDlls` value and rebuild.
- **A new Outlook build changed the ad row class**: open `inject.js`, update the selector, re-run the
  installer. No recompilation needed.

## Research notes

Useful if Outlook changes again:

- `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` is **ignored** by this app, both as a user environment
  variable and through the documented registry policy
  (`HKCU\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments`).
  Verified by reading the real `msedgewebview2.exe` command line.
- The ad used to come from `outlookads.live.com` (visible in the Chromium *Subresource Filter* rules
  and in Chromium's own ad-filter list), but on the current build nothing is fetched from it.
- The ad row can be inspected from outside with Windows UI Automation: the message list exposes
  `div[role="listitem"]` for real messages and plain `div` rows for ads, the latter containing an
  element whose text is the localized ad label.
- The C++ hook chain (IAT + vtable) follows the technique popularised by
  [valinet/NewOutlookPatcher](https://github.com/valinet/NewOutlookPatcher) (GPL-3.0), which does not work
  on the current build because its CSS selectors are outdated.

## Disclaimer

The DLL is **not code-signed**: SmartScreen or your antivirus may warn about it. The full source is in
`src\OutlookAdFix.cpp` and CI builds it from scratch, so you can verify it.

Application Verifier / Image File Execution Options is a powerful mechanism: use it only on machines you
control. The installer saves the previous `VerifierDlls` value and restores it on uninstall.

## Italiano

Rimuove le righe pubblicitarie dalla nuova app **Outlook per Windows**. L'annuncio non viene piu scaricato
da un dominio esterno, quindi bloccarlo via DNS non serve: viene disegnato dalla pagina di Outlook dentro
WebView2. La DLL `OutlookAdFix.dll` viene caricata dentro `olk.exe` (Application Verifier), aggancia WebView2
e inietta `inject.js`, che nasconde le righe annuncio dell'elenco messaggi.

1. `build\build.cmd` compila la DLL (scarica da sola l'SDK WebView2).
2. Doppio clic su `Avvia-Outlook-AdBlock.cmd` e scegli `[1] Installa`.
3. `[2] Rimuovi` ripristina tutto.

Interfaccia dello script in italiano, log in `%LOCALAPPDATA%\Remove-OutlookAds\adfix.log`.

## License

GPL-3.0 - see [LICENSE](LICENSE).
