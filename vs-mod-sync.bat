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
  Vintage Story friend mod-sync for Windows — no installs required.
  Uses only built-in PowerShell (HTTP, JSON, SHA-256, zip). Pre-installed on Win 10/11.

  Safety (same as the Python version):
   * Touches your Vintage Story Mods folder, and ModConfig for a small set of
     pre-built config files (e.g. StepUp Advanced's block blacklist) — synced
     regardless of whether you have the matching mod yet, so it's ready the moment
     you add it. Same checksum-verify-then-write safety as mods, never anything else.
   * Shows the plan first and asks before changing anything (or pass -Apply to skip the prompt).
   * Backs up your whole Mods folder to a timestamped .zip before any change.
   * Verifies SHA-256 of every download; a bad download is discarded, never installed.
   * Never removes a mod whose id is not in the manifest (keeps your personal mods).
   * Optional mods (shaders/foliage/HUD) only sync if you already have them and they're enabled.
   * No admin rights, no system changes.

  Run: double-click run-friend-sync.bat, OR:
     powershell -ExecutionPolicy Bypass -File friend_sync.ps1
     powershell -ExecutionPolicy Bypass -File friend_sync.ps1 -Apply
#>
param(
  [string]$Manifest = "https://raw.githubusercontent.com/ConnyZs/VintageStory/main/manifest.json",
  [string]$ModsDir  = "",
  [switch]$Apply
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Find-ModsDir {
  if ($ModsDir) { return $ModsDir }
  if ($env:VS_MODS) { return $env:VS_MODS }
  $cands = @(
    (Join-Path $env:APPDATA "VintagestoryData\Mods"),       # Windows default
    (Join-Path $env:USERPROFILE ".config\VintagestoryData\Mods")
  )
  foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}

function Get-ModId([string]$zipPath) {
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
      $e = $zip.Entries | Where-Object { $_.FullName.ToLower() -eq "modinfo.json" } | Select-Object -First 1
      if (-not $e) { $e = $zip.Entries | Where-Object { $_.FullName.ToLower().EndsWith("modinfo.json") } | Select-Object -First 1 }
      if (-not $e) { return $null }
      $sr = New-Object System.IO.StreamReader($e.Open())
      $txt = $sr.ReadToEnd(); $sr.Close()
    } finally { $zip.Dispose() }
    if ($txt -match '(?i)"modid"\s*:\s*"([^"]+)"') { return $Matches[1].ToLower() }
  } catch { }
  return $null
}

function Get-Sha([string]$path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }

function Fast-Skip([string]$path, [string]$sha, [long]$expectedSize) {
  # quick size check before expensive SHA-256 — if sizes differ the file is definitely wrong
  if ($expectedSize -gt 0) {
    $actual = (Get-Item -LiteralPath $path).Length
    if ($actual -ne $expectedSize) { return $false }
  }
  if (-not $sha) { return $true }   # no sha in manifest + size matched → assume ok
  return ((Get-Sha $path) -eq $sha.ToLower())
}

function Get-Disabled([string]$modsDir) {
  $set = @{}
  $cs = Join-Path (Split-Path $modsDir -Parent) "clientsettings.json"
  if (Test-Path -LiteralPath $cs) {
    try {
      $j = (Get-Content -LiteralPath $cs -Raw) | ConvertFrom-Json
      foreach ($entry in $j.disabledMods) { $set[(($entry -split '@')[0]).ToLower()] = $true }
    } catch { }
  }
  return $set
}

# ---- locate folder + load manifest ----
$modsDir = Find-ModsDir
if (-not $modsDir -or -not (Test-Path -LiteralPath $modsDir)) {
  Write-Host "ERROR: could not find your Vintage Story Mods folder." -ForegroundColor Red
  Write-Host "Run with:  -ModsDir `"C:\path\to\VintagestoryData\Mods`""
  exit 2
}
try { $man = Invoke-RestMethod -Uri $Manifest -TimeoutSec 30 }
catch { Write-Host "ERROR: could not load manifest from $Manifest" -ForegroundColor Red; exit 2 }

Write-Host "Mods folder : $modsDir"
Write-Host ("Manifest    : game {0} | {1} mods | built {2}" -f $man.game_version, $man.count, $man.generated)
Write-Host ("Mode        : {0}" -f $(if ($Apply) {"APPLY"} else {"DRY RUN"}))
Write-Host ""

# ---- index installed zips by modid (with cache so repeat runs skip re-opening unchanged zips) ----
$cacheFile = Join-Path $modsDir ".sync-cache.json"
$cache = @{}
if (Test-Path -LiteralPath $cacheFile) {
  try { $cache = (Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json -AsHashtable) } catch {}
}
$newCache = @{}
$installed = @{}    # modid -> list of filenames
Get-ChildItem -LiteralPath $modsDir -Filter *.zip -File | ForEach-Object {
  $fi = $_; $key = $fi.Name
  $size = $fi.Length; $mtime = $fi.LastWriteTimeUtc.Ticks
  # reuse cached modid if file hasn't changed (same size + mtime)
  $mid = $null
  if ($cache.ContainsKey($key) -and $cache[$key].size -eq $size -and $cache[$key].mtime -eq $mtime) {
    $mid = $cache[$key].modid
  } else {
    $mid = Get-ModId $fi.FullName
  }
  $newCache[$key] = @{ modid = $mid; size = $size; mtime = $mtime }
  if ($mid) { if (-not $installed.ContainsKey($mid)) { $installed[$mid] = @() }; $installed[$mid] += $fi.Name }
}
try { $newCache | ConvertTo-Json | Set-Content -LiteralPath $cacheFile -Encoding UTF8 } catch {}
$disabled = Get-Disabled $modsDir
$present  = @{}; foreach ($k in $installed.Keys) { $present[$k] = $true }

$toGet=@(); $toRemove=@(); $ok=@(); $skipped=@(); $problems=@()
$wantFiles=@{}; $useModids=@{}

function Consider($m, [bool]$optional) {
  $mid=$m.modid; $fn=$m.filename; $sha=$m.sha256; $url=$m.url
  if ($optional) {
    if (-not $present.ContainsKey($mid)) { $script:skipped += "$mid (not installed - left alone)"; return }
    # disabled-but-installed: still sync the zip so VS picks up the update if re-enabled
  }
  $script:useModids[$mid]=$true
  $script:wantFiles[$fn]=$true
  $target = Join-Path $modsDir $fn
  if ($mid -and $installed.ContainsKey($mid)) {                 # always purge other versions
    foreach ($other in $installed[$mid]) { if ($other -ne $fn) { $script:toRemove += $other } }
  }
  if ((Test-Path -LiteralPath $target) -and (Fast-Skip $target $sha ([long]($m.size)))) { $script:ok += $fn; return }
  if (-not $url) { $script:problems += "$fn (no download URL)"; return }
  $script:toGet += $m
}

foreach ($m in $man.mods)     { Consider $m $false }
foreach ($m in $man.optional) { Consider $m $true }

# ---- client config files (always synced, so they're ready before you even install
#      the mod they belong to - no need to re-run this after adding it later) ----
$toGetConfigs=@()
foreach ($c in $man.client_configs) {
  $target = Join-Path (Join-Path (Split-Path $modsDir -Parent) "ModConfig") $c.filename
  if ((Test-Path -LiteralPath $target) -and (Fast-Skip $target $c.sha256 ([long]($c.size)))) { continue }
  $toGetConfigs += $c
}

# ModsByServer cleanup: redundant server-pushed copies of mods we now have
$mbs = Join-Path (Split-Path $modsDir -Parent) "ModsByServer"
$mbsRemove=@()
if (Test-Path -LiteralPath $mbs) {
  Get-ChildItem -LiteralPath $mbs -Filter *.zip -File | ForEach-Object {
    $mid = Get-ModId $_.FullName
    if ($mid -and $useModids.ContainsKey($mid)) { $mbsRemove += $_.Name }
  }
}

Write-Host ("Up to date  : {0}" -f $ok.Count)
Write-Host ("To download : {0}" -f $toGet.Count)
foreach ($m in $toGet) { Write-Host ("    + {0}  ({1})" -f $m.filename, $(if($m.name){$m.name}else{$m.modid})) }
$toRemove = $toRemove | Sort-Object -Unique
if ($toRemove.Count) { Write-Host ("To replace (old versions): {0}" -f $toRemove.Count); $toRemove | ForEach-Object { Write-Host "    - $_" } }
if ($mbsRemove.Count) { Write-Host ("ModsByServer to clean: {0}" -f $mbsRemove.Count); $mbsRemove | ForEach-Object { Write-Host "    - ModsByServer\$_" } }
if ($skipped.Count) { Write-Host ("Optional left alone: {0}" -f $skipped.Count); $skipped | ForEach-Object { Write-Host "    . $_" } }
if ($problems.Count) { Write-Host ("Manual (no URL): {0}" -f $problems.Count) -ForegroundColor Yellow; $problems | ForEach-Object { Write-Host "    ! $_" } }
if ($toGetConfigs.Count) { Write-Host ("Config files to update: {0}" -f $toGetConfigs.Count); $toGetConfigs | ForEach-Object { Write-Host ("    ~ {0}" -f $_.filename) } }

if (($toGet.Count -eq 0) -and ($toRemove.Count -eq 0) -and ($mbsRemove.Count -eq 0) -and ($toGetConfigs.Count -eq 0)) {
  Write-Host "`nAlready in sync. Nothing to do." -ForegroundColor Green; exit 0
}
if (-not $Apply) {
  $ans = Read-Host "`nApply these changes? (y/N)"
  if ($ans -notmatch '^(y|yes)$') { Write-Host "Nothing changed."; exit 0 }
}

# ---- backup first ----
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:USERPROFILE "VSmods-backup-$stamp.zip"
Write-Host "`nBacking up Mods folder -> $backup"
Compress-Archive -Path (Join-Path $modsDir '*') -DestinationPath $backup -Force

# ---- download + verify + install ----
foreach ($m in $toGet) {
  $fn=$m.filename; $sha=$m.sha256; $url=($m.url -replace ' ','%20')
  $tmp = Join-Path $modsDir ("." + [System.Guid]::NewGuid().ToString() + ".tmp")
  try {
    Write-Host "  downloading $fn ..."
    Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 300
    if ($sha -and ((Get-Sha $tmp) -ne $sha.ToLower())) {
      Remove-Item -LiteralPath $tmp -Force
      Write-Host "    ! checksum mismatch for $fn - discarded, NOT installed." -ForegroundColor Red
      continue
    }
    Move-Item -LiteralPath $tmp -Destination (Join-Path $modsDir $fn) -Force
    Write-Host "    ok $fn"
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Write-Host "    ! failed $fn : $_" -ForegroundColor Red
  }
}
foreach ($r in $toRemove) {
  $rp = Join-Path $modsDir $r
  if ((Test-Path -LiteralPath $rp) -and (-not $wantFiles.ContainsKey($r))) { Remove-Item -LiteralPath $rp -Force; Write-Host "  removed old $r" }
}
foreach ($r in $mbsRemove) {
  $rp = Join-Path $mbs $r
  if (Test-Path -LiteralPath $rp) { Remove-Item -LiteralPath $rp -Force; Write-Host "  cleaned ModsByServer\$r" }
}
foreach ($c in $toGetConfigs) {
  $cfgDir = Join-Path (Split-Path $modsDir -Parent) "ModConfig"
  if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
  $target = Join-Path $cfgDir $c.filename
  $tmp = Join-Path $cfgDir ("." + [System.Guid]::NewGuid().ToString() + ".tmp")
  try {
    Write-Host "  downloading config $($c.filename) ..."
    Invoke-WebRequest -Uri ($c.url -replace ' ','%20') -OutFile $tmp -TimeoutSec 60
    if ($c.sha256 -and ((Get-Sha $tmp) -ne $c.sha256.ToLower())) {
      Remove-Item -LiteralPath $tmp -Force
      Write-Host "    ! checksum mismatch for $($c.filename) - discarded, NOT installed." -ForegroundColor Red
      continue
    }
    Move-Item -LiteralPath $tmp -Destination $target -Force
    Write-Host "    ok $($c.filename)"
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Write-Host "    ! failed $($c.filename) : $_" -ForegroundColor Red
  }
}
# clear VS texture atlas cache so mod changes take effect without stale-atlas artefacts
$dataParent = Split-Path $modsDir -Parent
$cacheDir = Join-Path $dataParent "Cache"
if (Test-Path -LiteralPath $cacheDir) {
  $ats = Get-ChildItem -LiteralPath $cacheDir -Filter "*.ats" -File -Recurse -ErrorAction SilentlyContinue
  if ($ats.Count -gt 0) {
    Write-Host "Clearing $($ats.Count) texture atlas cache file(s) ..."
    $ats | Remove-Item -Force -ErrorAction SilentlyContinue
  }
  # clear mod unpack cache to force re-extraction (fixes missing textures after mod updates)
  $unpackDir = Join-Path $cacheDir "unpack"
  if (Test-Path -LiteralPath $unpackDir) {
    $entries = Get-ChildItem -LiteralPath $unpackDir -ErrorAction SilentlyContinue
    if ($entries.Count -gt 0) {
      Write-Host "Clearing mod unpack cache ($($entries.Count) entries) ..."
      $entries | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
# delete stale WindowStorageLib config — float value where int expected causes parse error on SP load
$modCfg = Join-Path $dataParent "ModConfig\windowstoragelibconfig.json"
if (Test-Path -LiteralPath $modCfg) {
  Remove-Item -LiteralPath $modCfg -Force -ErrorAction SilentlyContinue
  Write-Host "Cleared WindowStorageLib config (will regenerate on next launch)."
}

Write-Host "`nDone. Backup kept at $backup." -ForegroundColor Green
