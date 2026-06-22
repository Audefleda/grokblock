<#
.SYNOPSIS
    grokblock.ps1 - Kombinierter Grok-Blocker fuer Windows
.DESCRIPTION
    Blockiert Grok-Dienste (api.x.ai, grok.com, www.grok.com, console.x.ai)
    via hosts-Datei, Windows-Firewall und Git-Clone-Sperre.
.EXAMPLE
    grokblock.bat --enable
    grokblock.bat --disable
    grokblock.bat --status
    grokblock.bat --test
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Status,
    [switch]$Test
)

$ErrorActionPreference = "Stop"

# === KONFIGURATION ===========================================================

$DOMAINS         = @("api.x.ai", "grok.com", "www.grok.com", "console.x.ai")
$HOSTS_FILE      = "$env:SystemRoot\System32\drivers\etc\hosts"
$MARKER_BEGIN    = "# >>> BLOCK GROK API - BEGIN"
$MARKER_END      = "# >>> BLOCK GROK API - END"
$FW_PREFIX       = "GrokBlock"
$BLOCKER_DIR     = "C:\ProgramData\grokblock"
$GIT_WRAPPER_CMD = "$BLOCKER_DIR\git.cmd"
$GIT_WRAPPER_PS1 = "$BLOCKER_DIR\git-wrapper.ps1"
$GIT_WATCHER     = "$BLOCKER_DIR\git-watcher.ps1"
$TASK_NAME       = "GrokBlockWatcher"
$LOG_FILE        = "$BLOCKER_DIR\git-block.log"

$BLOCKED_REPOS = @(
    "https://github.com/DE0CH/grok-frontend.git",
    "https://github.com/DE0CH/grok-frontend",
    "git@github.com:DE0CH/grok-frontend.git",
    "git@github.com:DE0CH/grok-frontend"
)

# =============================================================================

function Write-Info ($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "[ERR]  $msg" -ForegroundColor Red }

# === HILFSFUNKTIONEN =========================================================

function Resolve-GrokIPs {
    param([string]$Domain)
    try {
        $results = Resolve-DnsName -Name $Domain -Server "8.8.8.8" -Type A -ErrorAction Stop
        return @($results | Where-Object { $_.Type -eq "A" } | Select-Object -ExpandProperty IPAddress)
    } catch {
        $output = & nslookup $Domain 8.8.8.8 2>$null
        return @($output |
            Select-String '^\s*Address:\s*([\d\.]+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } |
            Where-Object { $_ -ne "8.8.8.8" })
    }
}

function Flush-Dns {
    Write-Info "DNS-Cache leeren..."
    & ipconfig /flushdns | Out-Null
}

function Find-RealGit {
    $candidates = @(Get-Command "git" -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike "*grokblock*" -and $_.Source -like "*.exe" })
    if ($candidates.Count -gt 0) { return $candidates[0].Source }
    foreach ($path in @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files\Git\bin\git.exe",
        "C:\Program Files (x86)\Git\cmd\git.exe"
    )) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

# === ENABLE ==================================================================

function Enable-DomainsBlock {
    Write-Host ""
    Write-Host "=== Grok-Domains-Sperre aktivieren ==="
    Write-Host ""

    # --- hosts-Datei ---
    Write-Info "hosts-Datei bearbeiten..."
    $hostsContent = Get-Content $HOSTS_FILE -Raw -ErrorAction SilentlyContinue
    if ($hostsContent -match [regex]::Escape($MARKER_BEGIN)) {
        Write-Warn "Eintraege in hosts-Datei bereits vorhanden. Ueberspringe."
    } else {
        $backup = "$HOSTS_FILE.bak_grok_$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $HOSTS_FILE $backup
        Write-Info "Backup erstellt: $backup"
        $newLines = "`r`n$MARKER_BEGIN`r`n"
        foreach ($domain in $DOMAINS) {
            $newLines += "127.0.0.1   $domain`r`n"
            $newLines += "0.0.0.0     $domain`r`n"
        }
        $newLines += $MARKER_END
        Add-Content -Path $HOSTS_FILE -Value $newLines -Encoding ASCII
        Write-Ok "hosts-Datei: Eintraege fuer alle Grok-Domains hinzugefuegt."
    }

    Flush-Dns

    # --- Windows-Firewall ---
    Write-Info "Windows-Firewall konfigurieren..."
    foreach ($domain in $DOMAINS) {
        $ips = Resolve-GrokIPs $domain
        if (-not $ips -or $ips.Count -eq 0) {
            Write-Warn "Konnte keine IPs fuer $domain aufloesen - ueberspringe Firewall-Regel."
            continue
        }
        Write-Info "Aufgeloeste IPs fuer ${domain}:"
        foreach ($ip in $ips) {
            Write-Host "    -> $ip"
            $ruleName = "${FW_PREFIX}_${domain}_${ip}"
            if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
                Write-Warn "Firewall-Regel '$ruleName' bereits vorhanden."
            } else {
                New-NetFirewallRule `
                    -DisplayName $ruleName `
                    -Direction Outbound `
                    -Action Block `
                    -Protocol TCP `
                    -RemoteAddress $ip `
                    -RemotePort @(80, 443) `
                    -Profile Any `
                    -Enabled True | Out-Null
                Write-Ok "Firewall-Regel erstellt: $ruleName"
            }
        }
    }

    Write-Ok "Grok-Domains-Sperre ist AKTIV."
}

function Enable-GitBlock {
    Write-Host ""
    Write-Host "=== Git-Repository-Sperre aktivieren ==="
    Write-Host ""

    if (-not (Test-Path $BLOCKER_DIR)) {
        New-Item -ItemType Directory -Path $BLOCKER_DIR | Out-Null
        Write-Info "Verzeichnis erstellt: $BLOCKER_DIR"
    }

    $realGit = Find-RealGit
    if (-not $realGit) {
        Write-Err "Git nicht gefunden. Bitte Git fuer Windows installieren."
        return
    }
    Write-Info "Reales Git gefunden: $realGit"

    # --- git-wrapper.ps1 ---
    Write-Info "Installiere Git-Wrapper-Skript -> $GIT_WRAPPER_PS1"
    $realGitEscaped = $realGit -replace "'", "''"
    $blockedList = ($BLOCKED_REPOS | ForEach-Object { "    '$_'" }) -join ",`r`n"
    $wrapperContent = @(
        '# Git Repository Blocker - Wrapper',
        '# Automatisch installiert - nicht manuell bearbeiten.',
        '',
        "`$REAL_GIT = '$realGitEscaped'",
        "`$BLOCKED_REPOS = @(",
        $blockedList,
        ')',
        '',
        'foreach ($arg in $args) {',
        '    foreach ($blocked in $BLOCKED_REPOS) {',
        '        if ($arg.ToLower() -eq $blocked.ToLower()) {',
        "            Write-Host `"BLOCKIERT: Das Klonen von '`$arg' ist nicht erlaubt.`" -ForegroundColor Red",
        '            try {',
        '                $log = New-Object System.Diagnostics.EventLog("Application")',
        '                $log.Source = "git-blocker"',
        "                `$log.WriteEntry(`"Clone blockiert: `$arg`", `"Warning`")",
        '            } catch {}',
        '            exit 1',
        '        }',
        '    }',
        '}',
        '',
        '& $REAL_GIT @args',
        'exit $LASTEXITCODE'
    )
    Set-Content -Path $GIT_WRAPPER_PS1 -Value $wrapperContent -Encoding UTF8
    Write-Ok "Git-Wrapper-Skript installiert."

    # --- git.cmd ---
    Write-Info "Installiere Git-Wrapper-CMD -> $GIT_WRAPPER_CMD"
    $cmdContent = @(
        '@echo off',
        ':: Git Repository Blocker Wrapper',
        ':: Automatisch installiert - nicht manuell bearbeiten.',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$GIT_WRAPPER_PS1`" %*",
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -Path $GIT_WRAPPER_CMD -Value $cmdContent -Encoding ASCII
    Write-Ok "Git-Wrapper-CMD installiert."

    # --- PATH erweitern (Blocker-Verzeichnis ganz vorne) ---
    $currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $pathParts   = @($currentPath -split ';' | Where-Object { $_ -ne $BLOCKER_DIR -and $_ -ne "" })
    [System.Environment]::SetEnvironmentVariable("PATH", ((@($BLOCKER_DIR) + $pathParts) -join ';'), "Machine")
    $env:PATH = ((@($BLOCKER_DIR) + @($env:PATH -split ';' | Where-Object { $_ -ne $BLOCKER_DIR -and $_ -ne "" })) -join ';')
    Write-Ok "$BLOCKER_DIR an den Anfang von PATH gesetzt."

    # --- git-watcher.ps1 ---
    Write-Info "Installiere Git-Watcher -> $GIT_WATCHER"
    $watcherContent = @(
        '# Git Repository Blocker - Watcher Daemon',
        '# Automatisch installiert - nicht manuell bearbeiten.',
        '',
        '$BLOCKED_PATTERNS = @("DE0CH/grok-frontend")',
        "`$LOG_FILE = '$LOG_FILE'",
        '',
        'while ($true) {',
        '    try {',
        '        $procs = Get-CimInstance Win32_Process -Filter "Name=''git.exe''" -ErrorAction SilentlyContinue',
        '        foreach ($proc in $procs) {',
        '            $cmdLine = $proc.CommandLine',
        '            foreach ($pattern in $BLOCKED_PATTERNS) {',
        '                if ($null -ne $cmdLine -and $cmdLine -like "*$pattern*") {',
        '                    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"',
        '                    "$ts`: Blockierter Clone-Versuch ($pattern) - PID: $($proc.ProcessId)" | Add-Content $LOG_FILE',
        '                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue',
        '                }',
        '            }',
        '        }',
        '    } catch {}',
        '    Start-Sleep -Seconds 1',
        '}'
    )
    Set-Content -Path $GIT_WATCHER -Value $watcherContent -Encoding UTF8
    Write-Ok "Git-Watcher installiert."

    # --- Scheduled Task ---
    Write-Info "Registriere Scheduled Task: $TASK_NAME"
    if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) {
        Write-Warn "Task bereits vorhanden - wird neu registriert."
        Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
    }

    $action    = New-ScheduledTaskAction `
                    -Execute "powershell.exe" `
                    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$GIT_WATCHER`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) `
                    -RestartCount 3 `
                    -RestartInterval (New-TimeSpan -Minutes 1) `
                    -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal `
                    -UserId "SYSTEM" `
                    -LogonType ServiceAccount `
                    -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $TASK_NAME `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal | Out-Null

    Start-ScheduledTask -TaskName $TASK_NAME
    Start-Sleep -Seconds 1

    $state = (Get-ScheduledTask -TaskName $TASK_NAME).State
    if ($state -eq "Running") {
        Write-Ok "Watcher-Task gestartet (Status: $state)."
    } else {
        Write-Warn "Watcher-Task Status: $state"
    }

    Write-Ok "Git-Repository-Sperre ist AKTIV."
}

# === DISABLE =================================================================

function Disable-DomainsBlock {
    Write-Host ""
    Write-Host "=== Grok-Domains-Sperre deaktivieren ==="
    Write-Host ""

    # --- hosts-Datei ---
    Write-Info "hosts-Datei bereinigen..."
    $lines = Get-Content $HOSTS_FILE
    $inBlock = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($MARKER_BEGIN)) { $inBlock = $true;  continue }
        if ($line -match [regex]::Escape($MARKER_END))   { $inBlock = $false; continue }
        if (-not $inBlock) { $newLines += $line }
    }
    if ($newLines.Count -ne $lines.Count) {
        $backup = "$HOSTS_FILE.bak_grok_$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $HOSTS_FILE $backup
        while ($newLines.Count -gt 0 -and $newLines[-1] -match '^\s*$') {
            $newLines = $newLines[0..($newLines.Count - 2)]
        }
        Set-Content -Path $HOSTS_FILE -Value $newLines -Encoding ASCII
        Write-Ok "Eintraege aus hosts-Datei entfernt."
    } else {
        Write-Warn "Keine Grok-Eintraege in hosts-Datei gefunden."
    }

    Flush-Dns

    # --- Windows-Firewall ---
    Write-Info "Firewall-Regeln entfernen..."
    $rules = @(Get-NetFirewallRule -DisplayName "${FW_PREFIX}_*" -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 0) {
        $rules | Remove-NetFirewallRule
        Write-Ok "$($rules.Count) Firewall-Regel(n) entfernt."
    } else {
        Write-Warn "Keine GrokBlock-Firewall-Regeln gefunden."
    }

    Write-Ok "Grok-Domains-Sperre ist DEAKTIVIERT."
}

function Disable-GitBlock {
    Write-Host ""
    Write-Host "=== Git-Repository-Sperre deaktivieren ==="
    Write-Host ""

    if (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) {
        Write-Info "Stoppe und entferne Scheduled Task..."
        Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
        Write-Ok "Scheduled Task entfernt."
    } else {
        Write-Warn "Scheduled Task '$TASK_NAME' nicht gefunden."
    }

    # PATH bereinigen
    $currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $newParts = @($currentPath -split ';' | Where-Object { $_ -ne $BLOCKER_DIR -and $_ -ne "" })
    if ($newParts.Count -lt ($currentPath -split ';').Count) {
        [System.Environment]::SetEnvironmentVariable("PATH", ($newParts -join ';'), "Machine")
        $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -ne $BLOCKER_DIR -and $_ -ne "" }) -join ';'
        Write-Ok "$BLOCKER_DIR aus PATH entfernt."
    } else {
        Write-Warn "$BLOCKER_DIR war nicht in PATH."
    }

    foreach ($file in @($GIT_WRAPPER_CMD, $GIT_WRAPPER_PS1, $GIT_WATCHER)) {
        if (Test-Path $file) {
            Remove-Item $file -Force
            Write-Ok "Geloescht: $file"
        } else {
            Write-Warn "Nicht gefunden: $file"
        }
    }

    if (Test-Path $LOG_FILE) {
        $reply = Read-Host "  Log-Datei ebenfalls loeschen? (j/N)"
        if ($reply -match '^[jJ]$') {
            Remove-Item $LOG_FILE -Force
            Write-Ok "Log-Datei geloescht."
        } else {
            Write-Info "Log-Datei beibehalten."
        }
    }

    if ((Test-Path $BLOCKER_DIR) -and -not (Get-ChildItem $BLOCKER_DIR -ErrorAction SilentlyContinue)) {
        Remove-Item $BLOCKER_DIR
        Write-Ok "Verzeichnis geloescht: $BLOCKER_DIR"
    }

    Write-Ok "Git-Repository-Sperre ist DEAKTIVIERT."
}

# === STATUS ==================================================================

function Show-Status {
    Write-Host ""
    Write-Host "======================================================="
    Write-Host "  grokblock - Status"
    Write-Host "======================================================="

    Write-Host ""
    Write-Host "--- Grok-Domains-Sperre ---"
    Write-Host ""

    $hostsContent = Get-Content $HOSTS_FILE -Raw -ErrorAction SilentlyContinue
    if ($hostsContent -match [regex]::Escape($MARKER_BEGIN)) {
        Write-Ok "hosts-Datei: BLOCKIERT"
    } else {
        Write-Err "hosts-Datei: NICHT BLOCKIERT"
    }

    $rules = @(Get-NetFirewallRule -DisplayName "${FW_PREFIX}_*" -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 0) {
        Write-Ok "Firewall-Regeln: $($rules.Count) Regel(n) vorhanden"
        $rules | ForEach-Object { Write-Host "    $($_.DisplayName)" }
    } else {
        Write-Err "Firewall-Regeln: KEINE vorhanden"
    }

    Write-Host ""
    Write-Host "  Verbindungstests:"
    foreach ($domain in $DOMAINS) {
        $padded = $domain.PadRight(22)
        Write-Host -NoNewline "    https://$padded "
        try {
            Invoke-WebRequest -Uri "https://$domain" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop | Out-Null
            Write-Host "ERREICHBAR (Sperre nicht wirksam!)" -ForegroundColor Red
        } catch {
            Write-Host "NICHT ERREICHBAR (Sperre wirksam)" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "--- Git-Repository-Sperre ---"
    Write-Host ""

    if ((Test-Path $GIT_WRAPPER_CMD) -and (Get-Content $GIT_WRAPPER_CMD -Raw) -match "Git Repository Blocker") {
        Write-Ok "Git-Wrapper-CMD: installiert ($GIT_WRAPPER_CMD)"
    } else {
        Write-Err "Git-Wrapper-CMD: NICHT installiert"
    }

    if (Test-Path $GIT_WRAPPER_PS1) {
        Write-Ok "Git-Wrapper-PS1: installiert ($GIT_WRAPPER_PS1)"
    } else {
        Write-Err "Git-Wrapper-PS1: NICHT installiert"
    }

    if (Test-Path $GIT_WATCHER) {
        Write-Ok "Git-Watcher: installiert ($GIT_WATCHER)"
    } else {
        Write-Err "Git-Watcher: NICHT installiert"
    }

    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        Write-Ok "Watcher-Task: $($task.State)"
    } else {
        Write-Err "Watcher-Task: NICHT vorhanden"
    }

    $sysPath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    if (($sysPath -split ';') -contains $BLOCKER_DIR) {
        Write-Ok "System-PATH-Eintrag: vorhanden"
    } else {
        Write-Err "System-PATH-Eintrag: NICHT vorhanden"
    }

    if (Test-Path $LOG_FILE) {
        $count = @(Get-Content $LOG_FILE).Count
        Write-Info "Git-Block-Log: $count blockierte Versuche"
        if ($count -gt 0) {
            Write-Host "  Letzte 5 Eintraege:"
            Get-Content $LOG_FILE -Tail 5 | ForEach-Object { Write-Host "    $_" }
        }
    }

    Write-Host ""
}

# === TEST ====================================================================

function Run-Tests {
    Write-Host ""
    Write-Host "======================================================="
    Write-Host "  grokblock - Tests"
    Write-Host "======================================================="
    Write-Host ""

    $pass = 0
    $fail = 0

    Write-Host "--- Grok-Domains ---"
    Write-Host ""
    foreach ($domain in $DOMAINS) {
        Write-Info "Verbindungstest zu https://${domain} ..."
        try {
            Invoke-WebRequest -Uri "https://$domain" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop | Out-Null
            Write-Err "$domain ERREICHBAR - Sperre nicht wirksam!"
            $fail++
        } catch {
            Write-Ok "$domain NICHT ERREICHBAR - Sperre wirksam."
            $pass++
        }
    }

    Write-Host ""
    Write-Host "--- Git-Repository-Sperre ---"
    Write-Host ""

    $negTarget = "$env:TEMP\test-gitblock-neg"
    Write-Info "NEGATIV-TEST: Blockiertes Repo klonen ..."
    Write-Host "  -> git clone https://github.com/DE0CH/grok-frontend.git $negTarget"
    & git clone "https://github.com/DE0CH/grok-frontend.git" $negTarget 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Err "NEGATIV-TEST FEHLGESCHLAGEN - Repo wurde NICHT blockiert!"
        Remove-Item $negTarget -Recurse -Force -ErrorAction SilentlyContinue
        $fail++
    } else {
        Write-Ok "NEGATIV-TEST BESTANDEN - Repo wurde blockiert!"
        $pass++
    }

    Write-Host ""
    $posTarget = "$env:TEMP\test-gitblock-pos"
    Write-Info "POSITIV-TEST: Erlaubtes Repo klonen ..."
    Write-Host "  -> git clone https://github.com/octocat/Hello-World.git $posTarget"
    & git clone "https://github.com/octocat/Hello-World.git" $posTarget 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "POSITIV-TEST BESTANDEN - Erlaubtes Repo funktioniert!"
        $pass++
    } else {
        Write-Err "POSITIV-TEST FEHLGESCHLAGEN - Erlaubtes Repo wurde blockiert!"
        $fail++
    }

    Remove-Item $negTarget, $posTarget -Recurse -Force -ErrorAction SilentlyContinue

    $total = $pass + $fail
    Write-Host ""
    Write-Host "-------------------------------------------------"
    if ($fail -eq 0) {
        Write-Ok "Alle Tests bestanden! ($pass/$total)"
    } else {
        Write-Err "$fail von $total Tests fehlgeschlagen!"
    }
    Write-Host "-------------------------------------------------"
    Write-Host ""
}

# === HAUPTPROGRAMM ===========================================================

function Show-Usage {
    Write-Host ""
    Write-Host "Verwendung: grokblock.bat [OPTION]"
    Write-Host ""
    Write-Host "Optionen:"
    Write-Host "  --enable    Alle Sperren aktivieren (Grok-Domains + Git-Clone)"
    Write-Host "  --disable   Alle Sperren aufheben"
    Write-Host "  --status    Aktuellen Status anzeigen"
    Write-Host "  --test      Tests ausfuehren"
    Write-Host ""
}

if ($Enable) {
    Write-Host ""
    Write-Host "======================================================="
    Write-Host "  grokblock - Alle Sperren aktivieren"
    Write-Host "======================================================="
    Enable-DomainsBlock
    Enable-GitBlock
    Write-Host ""
    Write-Host "======================================================="
    Write-Ok "Alle Sperren sind AKTIV."
    Write-Host "======================================================="
    Write-Host ""
    Write-Host "  Installierte Komponenten:"
    Write-Host "    Grok-Domains: hosts-Datei + Windows-Firewall"
    Write-Host "    Git-Block:    $GIT_WRAPPER_CMD"
    Write-Host "    Watcher:      Scheduled Task '$TASK_NAME'"
    Write-Host ""
    Write-Host "  Naechster Schritt:"
    Write-Host "    grokblock.bat --test"
    Write-Host ""
} elseif ($Disable) {
    Write-Host ""
    Write-Host "======================================================="
    Write-Host "  grokblock - Alle Sperren deaktivieren"
    Write-Host "======================================================="
    Disable-DomainsBlock
    Disable-GitBlock
    Write-Host ""
    Write-Host "======================================================="
    Write-Ok "Alle Sperren sind DEAKTIVIERT."
    Write-Host "======================================================="
    Write-Host ""
} elseif ($Status) {
    Show-Status
} elseif ($Test) {
    Run-Tests
} else {
    Show-Usage
    exit 1
}

exit 0
