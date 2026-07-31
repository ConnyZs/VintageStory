#!/bin/zsh
# Vintage Story mod-sync for macOS — no installs required.
# Uses only built-in tools: zsh, curl, shasum, unzip, zip, osascript.
# Double-click to run, or from Terminal:
#   ./vs-mod-sync.command           # dry run
#   ./vs-mod-sync.command --apply   # actually sync

setopt errexit nounset pipefail

MANIFEST_URL="https://raw.githubusercontent.com/ConnyZs/VintageStory/main/manifest.json"
APPLY=0
(( ${@[(I)--apply]} )) && APPLY=1 || true

# ── locate Mods folder ──────────────────────────────────────────────────────
typeset MODS_DIR="${VS_MODS:-}"
if [[ -z "$MODS_DIR" ]]; then
  for d in \
    "$HOME/Library/Application Support/VintagestoryData/Mods" \
    "$HOME/.config/VintagestoryData/Mods"; do
    [[ -d "$d" ]] && { MODS_DIR="$d"; break; }
  done
fi
if [[ -z "$MODS_DIR" || ! -d "$MODS_DIR" ]]; then
  print "ERROR: could not find your Vintage Story Mods folder."
  print "Run with:  VS_MODS=/path/to/Mods $0"
  read -r "?Press Enter to close..."; exit 2
fi
typeset DATA_DIR="${MODS_DIR:h}"

# ── download manifest ───────────────────────────────────────────────────────
typeset TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
typeset MAN="$TMP/manifest.json"
curl -fsSL "$MANIFEST_URL" -o "$MAN" || {
  print "ERROR: could not download manifest from $MANIFEST_URL"
  read -r "?Press Enter to close..."; exit 2
}

# ── parse manifest via JXA (osascript — built into every Mac, no Python needed) ──
# Emits: HDR<TAB>GAME_VER<TAB>COUNT<TAB>GENERATED
#   then: req|opt<TAB>MODID<TAB>FILENAME<TAB>SHA256<TAB>URL<TAB>NAME
typeset ALL_ROWS
ALL_ROWS=$(MAN_PATH="$MAN" osascript -l JavaScript << 'JS'
ObjC.import('Foundation');
const path = $.NSProcessInfo.processInfo.environment.objectForKey('MAN_PATH').js;
const raw = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(
  $.NSData.dataWithContentsOfFile(path), $.NSUTF8StringEncoding));
const d = JSON.parse(raw);
const rows = [['HDR', d.game_version||'?', d.count||0, d.generated||''].join('\t')];
for (const m of (d.mods||[]))
  rows.push(['req', m.modid||'', m.filename||'', m.sha256||'', (m.url||'').replace(/ /g,'%20'), m.name||''].join('\t'));
for (const m of (d.optional||[]))
  rows.push(['opt', m.modid||'', m.filename||'', m.sha256||'', (m.url||'').replace(/ /g,'%20'), m.name||''].join('\t'));
for (const m of (d.client_configs||[]))
  rows.push(['cfg', m.modid||'', m.filename||'', m.sha256||'', (m.url||'').replace(/ /g,'%20'), ''].join('\t'));
rows.join('\n');
JS
)

typeset HDR GAME_VER MOD_CNT GEN
HDR=$(print "$ALL_ROWS" | grep $'^HDR\t' | head -1)
GAME_VER=$(print "$HDR" | cut -f2)
MOD_CNT=$(print "$HDR"  | cut -f3)
GEN=$(print "$HDR"      | cut -f4)

print "Mods folder : $MODS_DIR"
print "Manifest    : game $GAME_VER | $MOD_CNT mods | built $GEN"
print "Mode        : $([[ $APPLY -eq 1 ]] && print APPLY || print 'DRY RUN')"
print ""

# ── read modid from a zip ───────────────────────────────────────────────────
get_modid() {
  local zf="$1" content="" inner
  content=$(unzip -p "$zf" modinfo.json 2>/dev/null) || {
    inner=$(unzip -Z1 "$zf" 2>/dev/null | grep -i 'modinfo\.json$' | head -1)
    [[ -n "$inner" ]] && content=$(unzip -p "$zf" "$inner" 2>/dev/null) || true
  }
  [[ -z "$content" ]] && return 0
  print "$content" | grep -i '"modid"' \
    | sed 's/.*"[Mm]od[Ii][Dd]"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | tr '[:upper:]' '[:lower:]' | head -1
}

# ── index installed zips by modid ───────────────────────────────────────────
typeset -A inst   # modid → pipe-separated filenames
for f in "$MODS_DIR"/*.zip(N); do
  local mid=$(get_modid "$f") fn="${f:t}"
  [[ -n "$mid" ]] && inst[$mid]="${inst[$mid]:+${inst[$mid]}|}$fn"
done

# ── disabled modids ─────────────────────────────────────────────────────────
typeset -A disabled
typeset CS="$DATA_DIR/clientsettings.json"
if [[ -f "$CS" ]]; then
  typeset DISABLED_LIST=""
  DISABLED_LIST=$(CS_PATH="$CS" osascript -l JavaScript << 'JS' 2>/dev/null || true
ObjC.import('Foundation');
const path = $.NSProcessInfo.processInfo.environment.objectForKey('CS_PATH').js;
const raw = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(
  $.NSData.dataWithContentsOfFile(path), $.NSUTF8StringEncoding));
try {
  const d = JSON.parse(raw);
  const dm = d.disabledMods || (d.stringListSettings && d.stringListSettings.disabledMods) || [];
  dm.map(e => String(e).split('@')[0].toLowerCase()).join('\n');
} catch(e) { ''; }
JS
  )
  while IFS= read -r mid; do
    [[ -n "$mid" ]] && disabled[$mid]=1
  done <<< "$DISABLED_LIST"
fi

# ── plan ─────────────────────────────────────────────────────────────────────
typeset -a to_dl to_rm skipped problems to_dl_cfg
typeset -A want_files use_modids
typeset -i ok_ct=0 cfg_ok_ct=0

consider_cfg() {
  # always synced, regardless of whether the matching mod is installed yet — so
  # the config is ready the moment you add the mod, no need to re-run this script
  local modid="$1" fname="$2" sha="$3" url="$4"
  local target="$DATA_DIR/ModConfig/$fname"
  if [[ -f "$target" ]]; then
    if [[ -z "$sha" || "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sha" ]]; then
      (( cfg_ok_ct++ )); return
    fi
  fi
  to_dl_cfg+=("$fname|$sha|$url")
}

consider() {
  local type="$1" modid="$2" fname="$3" sha="$4" url="$5" name="$6"
  if [[ "$type" = "opt" ]]; then
    if (( ! ${+inst[$modid]} )); then skipped+=("$modid (not installed — left alone)"); return; fi
    # disabled-but-installed: still sync so VS picks up the update if re-enabled
  fi
  use_modids[$modid]=1
  want_files[$fname]=1
  local target="$MODS_DIR/$fname"
  if (( ${+inst[$modid]} )); then
    local -a others=("${(s:|:)inst[$modid]}")
    for o in "${others[@]}"; do [[ "$o" != "$fname" ]] && to_rm+=("$o"); done
  fi
  if [[ -f "$target" ]]; then
    if [[ -z "$sha" || "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sha" ]]; then
      (( ok_ct++ )); return
    fi
  fi
  [[ -z "$url" ]] && { problems+=("$fname (no download URL)"); return; }
  to_dl+=("$modid|$fname|$sha|$url|$name")
}

while IFS=$'\t' read -r type modid fname sha url name; do
  [[ "$type" = "HDR" ]] && continue
  if [[ "$type" = "cfg" ]]; then
    consider_cfg "$modid" "$fname" "$sha" "$url"
  else
    consider "$type" "$modid" "$fname" "$sha" "$url" "$name"
  fi
done <<< "$ALL_ROWS"

# ModsByServer cleanup
typeset MBS="$DATA_DIR/ModsByServer"
typeset -a mbs_rm
if [[ -d "$MBS" ]]; then
  for f in "$MBS"/*.zip(N); do
    local mid=$(get_modid "$f") fn="${f:t}"
    (( ${+use_modids[$mid]} )) && mbs_rm+=("$fn") || true
  done
fi

# ── report ───────────────────────────────────────────────────────────────────
print "Up to date  : $ok_ct"
print "To download : ${#to_dl}"
for entry in "${to_dl[@]:-}"; do
  local mid fn nm; IFS='|' read -r mid fn _ _ nm <<< "$entry"
  print "    + $fn  (${nm:-$mid})"
done
if (( ${#to_rm} > 0 )); then
  local -a to_rm_u=("${(u)to_rm[@]}")
  print "To replace (old versions): ${#to_rm_u}"
  for r in "${to_rm_u[@]}"; do print "    - $r"; done
fi
if (( ${#mbs_rm} > 0 )); then
  print "ModsByServer to clean: ${#mbs_rm}"
  for r in "${mbs_rm[@]}"; do print "    - ModsByServer/$r"; done
fi
if (( ${#skipped} > 0 )); then
  print "Optional left alone: ${#skipped}"
  for s in "${skipped[@]}"; do print "    · $s"; done
fi
if (( ${#problems} > 0 )); then
  print "Manual (no URL): ${#problems}"
  for p in "${problems[@]}"; do print "    ! $p"; done
fi
if (( ${#to_dl_cfg} > 0 )); then
  print "Config files to update: ${#to_dl_cfg}"
  for entry in "${to_dl_cfg[@]}"; do
    local fn; IFS='|' read -r fn _ _ <<< "$entry"
    print "    ~ $fn"
  done
fi

if (( ${#to_dl} == 0 && ${#to_rm} == 0 && ${#mbs_rm} == 0 && ${#to_dl_cfg} == 0 )); then
  print "\nAlready in sync. Nothing to do."
  read -r "?Press Enter to close..."; exit 0
fi

if (( ! APPLY )); then
  read -r "?Apply these changes? (y/N): " ans
  [[ "$ans" =~ ^[Yy] ]] || { print "Nothing changed."; read -r "?Press Enter to close..."; exit 0; }
fi

# ── backup ───────────────────────────────────────────────────────────────────
typeset STAMP=$(date +%Y%m%d-%H%M%S)
typeset BACKUP="$HOME/VSmods-backup-$STAMP.zip"
print "\nBacking up Mods folder → $BACKUP"
(cd "$MODS_DIR" && zip -q "$BACKUP" *.zip 2>/dev/null) || true

# keep only the 2 most recent backups so these don't quietly pile up run after run —
# glob qualifiers: N = null-glob (no error if none match, needed under this script's
# `nounset`/`errexit`), om = order by mtime, newest first
typeset -a old_backups=("$HOME"/VSmods-backup-*.zip(Nom))
if (( ${#old_backups} > 2 )); then
  for old in "${(@)old_backups[3,-1]}"; do rm -f -- "$old"; done
fi

# ── download + verify + install ───────────────────────────────────────────────
for entry in "${to_dl[@]}"; do
  local fn sha url; IFS='|' read -r _ fn sha url _ <<< "$entry"
  local tmp="$TMP/$fn.tmp"
  print "  downloading $fn ..."
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
    if [[ -n "$sha" && "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" != "$sha" ]]; then
      rm -f "$tmp"; print "    ! checksum mismatch for $fn — discarded, NOT installed."
    else
      mv -f "$tmp" "$MODS_DIR/$fn"; print "    ok $fn"
    fi
  else
    rm -f "$tmp"; print "    ! download failed for $fn"
  fi
done

# ── remove old versions ──────────────────────────────────────────────────────
local -a to_rm_u=("${(u)to_rm[@]:-}")
for r in "${to_rm_u[@]:-}"; do
  local rp="$MODS_DIR/$r"
  [[ -f "$rp" && -z "${want_files[$r]+x}" ]] && { rm -f "$rp"; print "  removed old $r"; }
done

# ── clean ModsByServer ────────────────────────────────────────────────────────
for r in "${mbs_rm[@]:-}"; do
  [[ -f "$MBS/$r" ]] && { rm -f "$MBS/$r"; print "  cleaned ModsByServer/$r"; }
done

# ── download config files ────────────────────────────────────────────────────
typeset CFGDIR="$DATA_DIR/ModConfig"
[[ -d "$CFGDIR" ]] || mkdir -p "$CFGDIR"
for entry in "${to_dl_cfg[@]:-}"; do
  local fn sha url; IFS='|' read -r fn sha url <<< "$entry"
  local tmp="$TMP/$fn.tmp"
  print "  downloading config $fn ..."
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
    if [[ -n "$sha" && "$(shasum -a 256 "$tmp" | cut -d' ' -f1)" != "$sha" ]]; then
      rm -f "$tmp"; print "    ! checksum mismatch for $fn — discarded, NOT installed."
    else
      mv -f "$tmp" "$CFGDIR/$fn"; print "    ok $fn"
    fi
  else
    rm -f "$tmp"; print "    ! download failed for $fn"
  fi
done

# ── clear VS cache ────────────────────────────────────────────────────────────
typeset CACHE="$DATA_DIR/Cache"
if [[ -d "$CACHE" ]]; then
  print "Clearing game cache ..."
  rm -rf "$CACHE"
fi
typeset WSLCFG="$DATA_DIR/ModConfig/windowstoragelibconfig.json"
[[ -f "$WSLCFG" ]] && { rm -f "$WSLCFG"; print "Cleared WindowStorageLib config."; }

# ── keep placeonslabs disabled (crashes on Mac near sign blocks) ──────────────
if [[ -f "$CS" ]]; then
  CS_PATH="$CS" osascript -l JavaScript << 'JS' 2>/dev/null || true
ObjC.import('Foundation');
const path = $.NSProcessInfo.processInfo.environment.objectForKey('CS_PATH').js;
const raw = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(
  $.NSData.dataWithContentsOfFile(path), $.NSUTF8StringEncoding));
try {
  const d = JSON.parse(raw);
  let dm = d.disabledMods;
  if (!dm && d.stringListSettings) dm = d.stringListSettings.disabledMods;
  if (!dm) { d.disabledMods = []; dm = d.disabledMods; }
  if (!dm.some(e => String(e).split('@')[0].toLowerCase() === 'placeonslabs')) {
    dm.push('placeonslabs');
    const ns = $.NSString.alloc.initWithUTF8String(JSON.stringify(d, null, '\t'));
    ns.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  }
} catch(e) {}
JS
  print "  placeonslabs kept disabled in clientsettings.json."
fi

print "\nDone. Backup kept at $BACKUP."
read -r "?Press Enter to close..."
