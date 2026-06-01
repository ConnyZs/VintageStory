<#
  Vintage Story — mod installer / updater
  Works on a fresh install or an existing setup.
  Mandatory mods: always synced via bulk zip.
  Optional mods: auto-updated if already installed; asked individually if not.
  No admin rights required. Nothing changed outside your VS data folder.
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
  $cnt = (Get-ChildItem -LiteralPath $modsDir -Filter *.zip -File -ErrorAction SilentlyContinue).Count
  Say "Mods folder: $modsDir ($cnt mod(s) currently installed)" Green
}
Say ""

# ---- fetch manifest + modset ----
Say "Loading server mod list..." Gray
try   { $man    = Invoke-RestMethod -Uri $MANIFEST_URL -TimeoutSec 30 }
catch { Die "Could not reach the server mod list. Check your connection and try again." }
try   { $modset = Invoke-RestMethod -Uri $MODSET_URL -TimeoutSec 30 }
catch { $modset = $null }
if (-not $modset) { Die "Could not load download index (modset.json). Try again later." }

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

# ---- read modids already installed (from zip modinfo.json, cached) ----
# keyed modid -> filename. Uses .sync-cache.json (same format as friend_sync.ps1) to
# skip re-opening unchanged zips — makes repeated runs on a full Mods folder fast.
function Get-InstalledModids([string]$dir) {
  $ids      = @{}
  $cacheFile = Join-Path $dir ".sync-cache.json"
  $cache    = @{}
  if (Test-Path -LiteralPath $cacheFile) {
    try { $cache = (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json -AsHashtable) } catch {}
  }
  $newCache = @{}
  Get-ChildItem -LiteralPath $dir -Filter *.zip -File -ErrorAction SilentlyContinue | ForEach-Object {
    $fi = $_; $key = $fi.Name; $size = $fi.Length; $mtime = $fi.LastWriteTimeUtc.Ticks
    $mid = $null
    if ($cache.ContainsKey($key) -and $cache[$key].size -eq $size -and $cache[$key].mtime -eq $mtime) {
      $mid = $cache[$key].modid   # cache hit — skip opening the zip
    } else {
      try {
        $z = [System.IO.Compression.ZipFile]::OpenRead($fi.FullName)
        $e = $z.Entries | Where-Object { $_.Name -eq "modinfo.json" } | Select-Object -First 1
        if ($e) {
          $r = New-Object System.IO.StreamReader($e.Open()); $txt = $r.ReadToEnd(); $r.Close()
          if ($txt -match '(?i)"modid"\s*:\s*"([^"]+)"') { $mid = $Matches[1].ToLower() }
        }
        $z.Dispose()
      } catch {}
    }
    $newCache[$key] = @{ modid = $mid; size = $size; mtime = $mtime }
    if ($mid) { $ids[$mid] = $fi.Name }
  }
  try { $newCache | ConvertTo-Json | Set-Content -LiteralPath $cacheFile -Encoding UTF8 } catch {}
  return $ids
}

Say "Scanning installed mods..." Gray
$installedIds = Get-InstalledModids $modsDir
$existingFiles = @{}
Get-ChildItem -LiteralPath $modsDir -Filter *.zip -File -ErrorAction SilentlyContinue |
  ForEach-Object { $existingFiles[$_.Name] = $true }

# ---- mandatory mods: bulk download ----
$mandatoryDiff = @($man.mods | Where-Object { $_.filename -and -not $existingFiles.ContainsKey($_.filename) })
$mandatoryOk   = @($man.mods | Where-Object { $_.filename -and  $existingFiles.ContainsKey($_.filename) })

# ---- optional mods: per-mod decision ----
# already installed (any version) -> auto-update if newer filename
# not installed -> ask individually
$optUpdate = @()   # already have it, new version available -> silently update
$optAsk    = @()   # not installed -> prompt
$optSkip   = @()   # already up to date

foreach ($m in $man.optional) {
  if (-not $m.filename) { continue }
  $mid = if ($m.modid) { $m.modid.ToLower() } else { "" }
  if ($existingFiles.ContainsKey($m.filename)) {
    $optSkip += $m   # exact version already present
  } elseif ($mid -and $installedIds.ContainsKey($mid)) {
    $optUpdate += $m  # has it but older version
  } else {
    $optAsk += $m     # not installed at all
  }
}

Say ""

# show update summary
if ($mandatoryDiff.Count -eq 0 -and $optUpdate.Count -eq 0 -and $optAsk.Count -eq 0) {
  Say ("All {0} mods are already up to date." -f ($man.mods.Count + $man.optional.Count)) Green
  Say ""
  $go = Read-Host "Reinstall mandatory mods anyway? (y/N)"
  if ($go -notmatch '^(y|yes)$') { Say "Nothing changed."; pause; exit 0 }
  Say ""
}

if ($mandatoryOk.Count -gt 0 -and $mandatoryDiff.Count -gt 0) {
  Say ("{0} mandatory mod(s) already up to date." -f $mandatoryOk.Count) Gray
}
if ($mandatoryDiff.Count -gt 0) {
  Say ("{0} mandatory mod(s) to install / update:" -f $mandatoryDiff.Count) Yellow
  foreach ($m in $mandatoryDiff) {
    $label = if ($m.name) { $m.name } elseif ($m.modid) { $m.modid } else { $m.filename }
    Say "  + $label" White
  }
  Say ""
}

# auto-update optional mods already installed
$optChosen = @()
if ($optUpdate.Count -gt 0) {
  Say ("{0} optional mod(s) you have installed will be updated:" -f $optUpdate.Count) Cyan
  foreach ($m in $optUpdate) {
    $label = if ($m.name) { $m.name } elseif ($m.modid) { $m.modid } else { $m.filename }
    $old = $installedIds[(if ($m.modid) { $m.modid } else { "" }).ToLower()]
    Say "  * $label  ($old  ->  $($m.filename))" White
  }
  $optChosen += $optUpdate
  Say ""
}

# ask about optional mods not yet installed
foreach ($m in $optAsk) {
  $label = if ($m.name) { $m.name } elseif ($m.modid) { $m.modid } else { $m.filename }
  $ans = Read-Host "Install optional mod '$label'? (y/N)"
  if ($ans -match '^(y|yes)$') { $optChosen += $m }
}
if ($optAsk.Count -gt 0) { Say "" }

# ---- confirm ----
$totalNew = $mandatoryDiff.Count + $optChosen.Count
if ($totalNew -eq 0) {
  Say "Nothing to do." Green
  pause; exit 0
}
$go = Read-Host ("Ready to install {0} mod(s). Proceed? (Y/n)" -f $totalNew)
if ($go -match '^(n|no)$') { Say "Nothing changed."; pause; exit 0 }
Say ""

# ---- download mandatory bulk zip ----
$installedCount = 0
if ($mandatoryDiff.Count -gt 0 -or $mandatoryOk.Count -eq 0) {
  # download the full mandatory set as a zip (efficient even for partial updates)
  $sizeMB = [math]::Round($modset.server_size / 1MB, 0)
  Say "Downloading mandatory mods ($sizeMB MB)..." White
  $tmp = Join-Path $env:TEMP ("vs_modset_" + [System.Guid]::NewGuid().ToString() + ".zip")
  try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "VS-Setup/1.0")
    $wc.DownloadFile($modset.server_url, $tmp)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
    foreach ($entry in $zip.Entries) {
      if ($entry.Name -eq "") { continue }
      $dest = Join-Path $modsDir $entry.Name
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
      $installedCount++
    }
    $zip.Dispose()
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Die "Mandatory mods download failed: $_"
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
  Say "Mandatory mods installed." Green
}

# ---- download optional mods individually ----
if ($optChosen.Count -gt 0) {
  Say "Downloading optional mods..." White
  $wc2 = New-Object System.Net.WebClient
  $wc2.Headers.Add("User-Agent", "VS-Setup/1.0")
  foreach ($m in $optChosen) {
    $label = if ($m.name) { $m.name } elseif ($m.modid) { $m.modid } else { $m.filename }
    $dest  = Join-Path $modsDir $m.filename
    # remove old version if present
    $mid = if ($m.modid) { $m.modid.ToLower() } else { "" }
    if ($mid -and $installedIds.ContainsKey($mid)) {
      $oldFile = Join-Path $modsDir $installedIds[$mid]
      if ((Test-Path -LiteralPath $oldFile) -and $installedIds[$mid] -ne $m.filename) {
        Remove-Item -LiteralPath $oldFile -Force
      }
    }
    try {
      Say "  $label" Gray
      $wc2.DownloadFile($m.url, $dest)
      $installedCount++
    } catch {
      Say "  ! Failed to download $label : $_" Red
    }
  }
}

Say ""
Say "============================================" Green
Say "  Done! $installedCount mod(s) installed." Green
Say "============================================" Green
Say ""
Say "Start Vintage Story and connect to the server." White
Say "The game will load the new mods automatically." Gray
Say ""
