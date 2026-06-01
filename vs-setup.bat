@echo off
setlocal
set "T=%TEMP%\vsmodsync_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' | Select-Object -Skip 9 | Set-Content -LiteralPath $env:T -Encoding UTF8"
powershell -NoProfile -ExecutionPolicy Bypass -File "%T%"
del "%T%" 2>nul
echo.
pause
exit /b
<#
  Vintage Story — mod installer / updater
  Works on a fresh install or an existing setup.
  Checks game version, shows which mods change, handles optional visual mods.
  No admin rights required. Nothing is changed outside your VS data folder.
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$MANIFEST_URL = "https://raw.githubusercontent.com/ConnyZs/VintageStory/main/manifest.json"
$MODSET_URL   = "https://raw.githubusercontent.com/ConnyZs/VintageStory/main/modset.json"
$SERVER_NAME  = "Vintage Story"

function Say([string]$msg, [string]$col="White") { Write-Host $msg -ForegroundColor $col }
function Die([string]$msg) { Say "`n$msg" Red; Write-Host ""; pause; exit 1 }

Say ""
Say "============================================" Cyan
Say "  $SERVER_NAME — mod installer" Cyan
Say "============================================" Cyan
Say ""

# ---- locate VS ----
function Find-VSData {
  $cands = @(
    (Join-Path $env:APPDATA     "VintagestoryData"),
    (Join-Path $env:USERPROFILE ".config\VintagestoryData"),
    (Join-Path $env:USERPROFILE "AppData\Roaming\VintagestoryData")
  )
  foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
  return (Join-Path $env:APPDATA "VintagestoryData")
}

function Find-VSExe {
  $cands = @(
    (Join-Path $env:ProgramFiles        "Vintagestory\Vintagestory.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Vintagestory\Vintagestory.exe"),
    (Join-Path $env:LOCALAPPDATA        "Programs\Vintagestory\Vintagestory.exe"),
    (Join-Path $env:APPDATA             "Vintagestory\Vintagestory.exe")
  )
  foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}

$vsExe = Find-VSExe
if (-not $vsExe) {
  Say "Vintage Story does not appear to be installed." Yellow
  Say "You need to buy and install the game first:" Yellow
  Say "  https://www.vintagestory.at/buy.html" Cyan
  Say ""
  $open = Read-Host "Open the purchase page in your browser? (y/N)"
  if ($open -match '^(y|yes)$') { Start-Process "https://www.vintagestory.at/buy.html" }
  pause; exit 0
}
Say "Found Vintage Story at: $vsExe" Green

# ---- current VS version ----
$vsVerObj = $null
$vsVerDisplay = $null
try {
  $raw = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($vsExe).FileVersion
  $vsVerObj = [Version]$raw
  $vsVerDisplay = ("{0}.{1}.{2}" -f $vsVerObj.Major, $vsVerObj.Minor, $vsVerObj.Build)
} catch {}

# ---- Mods folder ----
$vsData  = Find-VSData
$modsDir = Join-Path $vsData "Mods"
if (-not (Test-Path -LiteralPath $modsDir)) {
  Say "Creating Mods folder at: $modsDir" Yellow
  New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
} else {
  $existing = (Get-ChildItem -LiteralPath $modsDir -Filter *.zip -File).Count
  Say "Mods folder: $modsDir ($existing mod(s) currently installed)" Green
}
Say ""

# ---- fetch manifest + modset ----
Say "Loading server mod list..." Gray
try   { $man = Invoke-RestMethod -Uri $MANIFEST_URL -TimeoutSec 30 }
catch { Die "Could not reach the server mod list. Check your connection and try again." }
try   { $modset = Invoke-RestMethod -Uri $MODSET_URL -TimeoutSec 30 }
catch { $modset = $null }

Say ("Server: game v{0} | {1} mods" -f $man.game_version, $man.count) Cyan
Say ""

# ---- game version check ----
if ($vsVerObj -and $man.game_version) {
  try {
    $srvVer = [Version]$man.game_version
    if ($srvVer -gt $vsVerObj) {
      Say ("Game update required: you have {0}, server needs {1}" -f $vsVerDisplay, $man.game_version) Yellow
      Say ""
      $upd = Read-Host "Open the VS download page to update the game? (Y/n)"
      if ($upd -notmatch '^(n|no)$') {
        Start-Process "https://www.vintagestory.at/downloads.html"
        Say ""
        Say "Install VS $($man.game_version), then run this script again to get the mods." White
        pause; exit 0
      }
      Say ""
      Say "Skipping game update. Mods may not load correctly on your version." Yellow
      Say ""
      $cont = Read-Host "Update mods anyway? (Y/n)"
      if ($cont -match '^(n|no)$') { Say "Nothing changed."; pause; exit 0 }
      Say ""
    }
  } catch {}
}

# ---- optional visual mods ----
$includeCosmetics = $false
$cosmeticNames = if ($modset -and $modset.client_only) { $modset.client_only } else { @() }
if ($cosmeticNames.Count) {
  Say ("Optional visual mods: {0}" -f ($cosmeticNames -join ", ")) Yellow
  Say "These improve looks but are not required to play." Gray
  $ans = Read-Host "Include them? (y/N)"
  $includeCosmetics = ($ans -match '^(y|yes)$')
  Say ""
}

# ---- mod diff ----
$existingFiles = @{}
Get-ChildItem -LiteralPath $modsDir -Filter *.zip -File -ErrorAction SilentlyContinue |
  ForEach-Object { $existingFiles[$_.Name] = $true }

$allMods = @($man.mods)
if ($includeCosmetics) { $allMods += @($man.optional) }

$toInstall = @($allMods | Where-Object { $_.filename -and -not $existingFiles.ContainsKey($_.filename) })
$alreadyOk = @($allMods | Where-Object { $_.filename -and  $existingFiles.ContainsKey($_.filename) })

if ($toInstall.Count -eq 0) {
  Say ("All {0} mods are already up to date." -f $allMods.Count) Green
  Say ""
  $go = Read-Host "Reinstall anyway? (y/N)"
  if ($go -notmatch '^(y|yes)$') { Say "Nothing changed."; pause; exit 0 }
} else {
  if ($alreadyOk.Count -gt 0) {
    Say ("{0} mod(s) already up to date." -f $alreadyOk.Count) Gray
  }
  Say ("{0} mod(s) to install / update:" -f $toInstall.Count) Yellow
  foreach ($m in $toInstall) {
    $label = if ($m.name) { $m.name } elseif ($m.modid) { $m.modid } else { $m.filename }
    Say "  + $label" White
  }
  Say ""
  $go = Read-Host "Install now? (Y/n)"
  if ($go -match '^(n|no)$') { Say "Nothing changed."; pause; exit 0 }
}
Say ""

# ---- pick download URL ----
if ($modset) {
  $url    = if ($includeCosmetics) { $modset.full_url    } else { $modset.server_url    }
  $sizeMB = [math]::Round((if ($includeCosmetics) { $modset.full_size } else { $modset.server_size }) / 1MB, 0)
} else {
  # fallback: derive URL from individual mod entries (slower but works without modset.json)
  Die "Could not load download index. Try again later."
}

# ---- download ----
$tmp = Join-Path $env:TEMP ("vs_modset_" + [System.Guid]::NewGuid().ToString() + ".zip")
Say "Downloading mods ($sizeMB MB)..." White
try {
  $wc = New-Object System.Net.WebClient
  $wc.Headers.Add("User-Agent", "VS-Setup/1.0")
  $wc.DownloadFile($url, $tmp)
} catch {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
  Die "Download failed: $_"
}
Say "Download complete." Green

# ---- extract into Mods folder ----
Say "Installing mods..." White
try {
  $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
  $installed = 0
  foreach ($entry in $zip.Entries) {
    if ($entry.Name -eq "") { continue }
    $dest = Join-Path $modsDir $entry.Name
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
    $installed++
  }
  $zip.Dispose()
} catch {
  Die "Could not extract mods: $_"
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
}

Say ""
Say "============================================" Green
Say "  Done! $installed mods installed." Green
Say "============================================" Green
Say ""
Say "Start Vintage Story and connect to the server." White
Say "The game will load the new mods automatically." Gray
Say ""
pause
