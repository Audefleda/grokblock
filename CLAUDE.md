# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Zweck

`grokblock.sh` ist ein macOS-Systemadministrations-Skript, das zwei unabhängige Sperrmechanismen kombiniert:

1. **Grok-Domains-Sperre** (`api.x.ai`, `grok.com`, `www.grok.com`, `console.x.ai`): Blockiert über `/etc/hosts` (DNS-Umleitung auf 127.0.0.1/0.0.0.0) und `pf`-Firewall (IP-basiert via Anchor `block_grok`).
2. **Git-Repository-Sperre**: Blockiert das Klonen bestimmter Repos via Git-Wrapper (`/usr/local/bin/git` shadowt `/usr/bin/git`) plus einem Watcher-Daemon (`/usr/local/bin/git-watcher.sh`), der als LaunchDaemon (`com.gitblock.watcher`) läuft und laufende Clone-Prozesse per `kill` beendet.

## Skripte

| Datei | Plattform |
|---|---|
| `grokblock.sh` | macOS (bash/zsh) |
| `grokblock.ps1` | Windows (PowerShell 5.1+) |

## Verwendung

**macOS:**
```bash
sudo ./grokblock.sh --enable    # Alle Sperren aktivieren
sudo ./grokblock.sh --disable   # Alle Sperren aufheben
sudo ./grokblock.sh --status    # Status anzeigen
sudo ./grokblock.sh --test      # Tests ausführen (curl + git clone)
```
Erfordert Root-Rechte (`sudo`). Kompatibel mit bash und zsh.

**Windows** (PowerShell als Administrator):
```powershell
powershell -ExecutionPolicy Bypass -File .\grokblock.ps1 -Enable
powershell -ExecutionPolicy Bypass -File .\grokblock.ps1 -Disable
powershell -ExecutionPolicy Bypass -File .\grokblock.ps1 -Status
powershell -ExecutionPolicy Bypass -File .\grokblock.ps1 -Test
```
Erfordert Administrator-Rechte (`#Requires -RunAsAdministrator`).

## Architektur (macOS — grokblock.sh)

Das Skript ist in eigenständige Funktionen gegliedert:

| Funktion | Zuständigkeit |
|---|---|
| `enable_grok_api_block` | /etc/hosts-Einträge für alle Domains + pf-Anchor anlegen und laden |
| `enable_git_block` | Git-Wrapper, Watcher-Skript und LaunchDaemon installieren |
| `disable_grok_api_block` | /etc/hosts bereinigen, pf-Anchor entfernen |
| `disable_git_block` | LaunchDaemon stoppen, Wrapper/Watcher/plist löschen |
| `do_status` | Alle Komponenten prüfen + curl-Verbindungstest |
| `do_test` | curl-Test + git-clone Negativ-/Positiv-Test |
| `resolve_ips` | DNS-Auflösung via `dig`/`nslookup`/`host` (Fallback-Kette) |
| `get_unique_patterns` | Dedupliziert Repo-URLs zu `github.com/DE0CH/grok-frontend`-Mustern |

**Marker-Prinzip:** Alle Einträge in `/etc/hosts` und `/etc/pf.conf` werden zwischen `# >>> BLOCK GROK API - BEGIN` und `# >>> BLOCK GROK API - END` eingefasst. `--disable` entfernt exakt diesen Block via `sed -i ''`. Die zu blockierenden Domains stehen in der Variable `DOMAINS` (leerzeichen-separiert) und werden in allen Funktionen per `for domain in $DOMAINS` iteriert.

**Git-Wrapper-Mechanismus:** Der Wrapper wird als Here-Doc mehrstufig zusammengebaut (Konstanten-Block + Blockliste + Logik-Block), da die Liste geblockte Repos zur Installationszeit eingebettet werden muss.

## Architektur (Windows — grokblock.ps1)

| Funktion | Zuständigkeit |
|---|---|
| `Enable-DomainsBlock` | hosts-Datei + Windows-Firewall-Regeln (`New-NetFirewallRule`) |
| `Enable-GitBlock` | git.cmd + git-wrapper.ps1 + git-watcher.ps1 + Scheduled Task |
| `Disable-DomainsBlock` | hosts-Einträge entfernen, Firewall-Regeln per Präfix `GrokBlock_*` löschen |
| `Disable-GitBlock` | Scheduled Task stoppen/löschen, Dateien entfernen, PATH bereinigen |
| `Show-Status` | Alle Komponenten prüfen + `Invoke-WebRequest`-Verbindungstest |
| `Run-Tests` | `Invoke-WebRequest`-Test + git-clone Negativ-/Positiv-Test |
| `Resolve-GrokIPs` | DNS-Auflösung via `Resolve-DnsName` mit nslookup-Fallback |
| `Find-RealGit` | Sucht das echte `git.exe` außerhalb von `C:\ProgramData\grokblock` |

**Git-Blocking-Mechanismus (Windows):** Zwei Dateien arbeiten zusammen — `git.cmd` (in `C:\ProgramData\grokblock\`) ruft `git-wrapper.ps1` auf, das die Argumente gegen die Blockliste prüft und dann das echte `git.exe` weiterleitet. Das Verzeichnis wird an den Anfang von `PATH` (System-Umgebungsvariable) gesetzt, sodass `git` im CMD und PowerShell abgefangen wird.

**Watcher (Windows):** Ein PowerShell-Skript (`git-watcher.ps1`) läuft als Scheduled Task unter `SYSTEM`, überwacht per `Get-CimInstance Win32_Process` laufende `git.exe`-Prozesse und beendet sie per `Stop-Process`, wenn die Kommandozeile ein blockiertes Muster enthält.

**Firewall (Windows):** Regeln werden per `New-NetFirewallRule` mit Präfix `GrokBlock_<domain>_<ip>` angelegt. `--disable` findet sie per Wildcard `GrokBlock_*` und löscht alle auf einmal.

## Installierte Komponenten (nach `--enable`)

**macOS:**
- `/etc/hosts` — neue Zeilen mit 127.0.0.1 / 0.0.0.0 für alle Domains
- `/etc/pf.anchors/block_grok` — pf-Regeln mit aufgelösten IPs
- `/etc/pf.conf` — Anchor-Eintrag (in Marker eingefasst)
- `/usr/local/bin/git` — Wrapper-Skript (shadowt `/usr/bin/git`)
- `/usr/local/bin/git-watcher.sh` — Watcher-Daemon
- `/Library/LaunchDaemons/com.gitblock.watcher.plist` — LaunchDaemon-Konfiguration
- `/var/log/git-block.log` — Protokoll blockierter Clone-Versuche

**Windows:**
- `%SystemRoot%\System32\drivers\etc\hosts` — Einträge für alle Domains
- Windows-Firewall-Regeln mit Präfix `GrokBlock_*` (outbound TCP 80/443)
- `C:\ProgramData\grokblock\git.cmd` — CMD-Wrapper (steht vorne in PATH)
- `C:\ProgramData\grokblock\git-wrapper.ps1` — PowerShell-Blocklist-Logik
- `C:\ProgramData\grokblock\git-watcher.ps1` — Watcher-Daemon
- Scheduled Task `GrokBlockWatcher` (läuft als SYSTEM beim Start)
- `C:\ProgramData\grokblock\git-block.log` — Protokoll blockierter Clone-Versuche

## Wichtige Einschränkungen

- Der Git-Wrapper blockiert nur exakte URL-Übereinstimmungen (case-insensitive Gleichheit, kein Substring-Match).
- Der Watcher-Daemon erkennt Prozesse über `pgrep -f "git.*<pattern>"` — der Pattern ist der deduplizierte Pfad-Anteil (z. B. `DE0CH/grok-frontend`).
- pf-Firewall-Regeln basieren auf zum Aktivierungszeitpunkt aufgelösten IPs; bei IP-Wechsel der Domain ist `--disable` + `--enable` nötig.
- Backups von `/etc/hosts` und `/etc/pf.conf` werden mit Zeitstempel-Suffix angelegt (z. B. `.bak_grok_20240101120000`) und nicht automatisch bereinigt.
