<#
  Vintage Story — one-click mod setup
  Downloads the full server modset and installs it into your Mods folder.
  Works even if you have never installed mods before.
  No admin rights required. Nothing is changed outside your VS data folder.
#>
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$MANIFEST_URL = "https://raw.githubusercontent.com/ConnyZs/VintageStory/main/manifest.json"
$SERVER_NAME  = "Vintage Story"

# ---- friendly helpers ----
function Say([string]$msg, [string]$col="White") { Write-Host $msg -ForegroundColor $col }
function Die([string]$msg) { Say "`n$msg" Red; Write-Host ""; pause; exit 1 }

Say ""
Say "============================================" Cyan
Say "  $SERVER_NAME — mod setup" Cyan
Say "============================================" Cyan
Say ""

# ---- locate VS data directory ----
function Find-VSData {
  $cands = @(
    (Join-Path $env:APPDATA     "VintagestoryData"),
    (Join-Path $env:USERPROFILE ".config\VintagestoryData"),
    (Join-Path $env:USERPROFILE "AppData\Roaming\VintagestoryData")
  )
  foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
  # VS installed but never launched? create the default data dir
  $default = Join-Path $env:APPDATA "VintagestoryData"
  return $default
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

$vsData = Find-VSData
$modsDir = Join-Path $vsData "Mods"
if (-not (Test-Path -LiteralPath $modsDir)) {
  Say "Creating Mods folder at: $modsDir" Yellow
  New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
} else {
  $existing = (Get-ChildItem -LiteralPath $modsDir -Filter *.zip -File).Count
  Say "Mods folder: $modsDir ($existing mod(s) currently installed)" Green
}
Say ""

# ---- load manifest ----
Say "Loading server mod list..." Gray
try { $man = Invoke-RestMethod -Uri $MANIFEST_URL -TimeoutSec 30 }
catch { Die "Could not reach the server mod list. Check your connection and try again." }
Say ("Server: game v{0} | {1} mods" -f $man.game_version, $man.count) Cyan
Say ""

# ---- offer client cosmetics ----
$includeCosmetics = $false
if ($man.modset.client_only -and $man.modset.client_only.Count) {
  $names = $man.modset.client_only -join ", "
  Say "Optional visual mods are available: $names" Yellow
  Say "These improve looks but are not required to play on the server." Gray
  $ans = Read-Host "Include them? (y/N)"
  $includeCosmetics = ($ans -match '^(y|yes)$')
}

$url  = if ($includeCosmetics) { $man.modset.full_url  } else { $man.modset.server_url  }
$cnt  = if ($includeCosmetics) { $man.modset.full_count } else { $man.modset.server_count }
$sizeMB = [math]::Round((if ($includeCosmetics) { $man.modset.full_size } else { $man.modset.server_size }) / 1MB, 0)

Say ("Ready to install {0} mods ({1} MB)." -f $cnt, $sizeMB) White
Say "This will not remove any personal mods you have installed." Gray
Say ""
$go = Read-Host "Install now? (Y/n)"
if ($go -match '^(n|no)$') { Say "Nothing changed."; pause; exit 0 }
Say ""

# ---- download modset zip ----
$tmp = Join-Path $env:TEMP ("vs_modset_" + [System.Guid]::NewGuid().ToString() + ".zip")
Say "Downloading mods... (this may take a minute)" White
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
    if ($entry.Name -eq "") { continue }   # skip directory entries
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
