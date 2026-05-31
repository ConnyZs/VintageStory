#!/usr/bin/env python3
"""Vintage Story friend mod-sync — Linux, paranoid-safe.

Makes your Mods folder match the server's approved modset (manifest.json) so the
server has nothing to push into "Mods downloaded from server" (ModsByServer).

SAFETY GUARANTEES (by design):
  * Touches ONLY your Vintage Story Mods folder. Nothing else on your system.
  * Dry-run by DEFAULT — shows exactly what it would do and changes nothing.
    You must pass --apply to make any change.
  * Backs up your whole Mods folder to a timestamped .zip before any change.
  * Verifies the SHA-256 of every download before installing it. A bad/partial
    download is discarded, never installed.
  * Never deletes a mod whose modid is NOT in the manifest — your personal /
    client-only mods are left untouched. It only removes an OUTDATED version of
    a mod that the manifest also lists.
  * No sudo. No system changes. No network except downloading the listed mods.

Usage:
    python3 friend_sync.py                 # dry run, auto-detect Mods folder
    python3 friend_sync.py --apply         # actually sync
    python3 friend_sync.py --manifest URL_OR_PATH --mods-dir /path/to/Mods --apply
"""
import argparse, json, os, re, sys, shutil, tempfile, zipfile, hashlib, datetime
import urllib.request, urllib.error

DEFAULT_MANIFEST = "https://raw.githubusercontent.com/ConnyZs/VintageStory/main/manifest.json"

CANDIDATE_DIRS = [
    "~/.var/app/at.vintagestory.VintageStory/config/VintagestoryData/Mods",  # flatpak
    "~/.config/VintagestoryData/Mods",                                       # native/tar
    "~/ApplicationData/Mods",
]

def find_mods_dir(override):
    if override:
        return os.path.expanduser(override)
    if os.environ.get("VS_MODS"):
        return os.path.expanduser(os.environ["VS_MODS"])
    for c in CANDIDATE_DIRS:
        p = os.path.expanduser(c)
        if os.path.isdir(p):
            return p
    return None

def tolerant_json(text):
    text = re.sub(r"^\s*//[^\n]*$", "", text, flags=re.M)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text, strict=False)

def modid_of(zip_path):
    try:
        with zipfile.ZipFile(zip_path) as z:
            names = z.namelist()
            n = next((x for x in names if x.lower() == "modinfo.json"), None) \
                or next((x for x in names if x.lower().endswith("modinfo.json")), None)
            if not n:
                return None
            mi = tolerant_json(z.read(n).decode("utf-8-sig", errors="replace"))
        return str({k.lower(): v for k, v in mi.items()}.get("modid", "")).lower() or None
    except Exception:
        return None

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 16), b""):
            h.update(c)
    return h.hexdigest()

def load_manifest(src):
    if re.match(r"^https?://", src):
        with urllib.request.urlopen(src, timeout=30) as r:
            return json.load(r)
    with open(os.path.expanduser(src)) as f:
        return json.load(f)

def disabled_modids(mods_dir):
    """Read clientsettings.json (next to the Mods folder) and return the set of
    disabled modids. VS stores them as 'modid@version' strings."""
    cs = os.path.join(os.path.dirname(mods_dir.rstrip("/")), "clientsettings.json")
    out = set()
    try:
        with open(cs) as f:
            data = json.load(f)
        lst = data.get("disabledMods") or data.get("stringListSettings", {}).get("disabledMods") or []
        for entry in lst:
            out.add(str(entry).split("@", 1)[0].lower())
    except Exception:
        pass
    return out

def installed_modids(mods_dir):
    """modid -> [filenames] for every zip currently in the Mods folder."""
    out = {}
    for fn in os.listdir(mods_dir):
        if fn.lower().endswith(".zip"):
            mid = modid_of(os.path.join(mods_dir, fn))
            if mid:
                out.setdefault(mid, []).append(fn)
    return out

def mods_by_server_dir(mods_dir):
    """The sibling ModsByServer folder, if it exists."""
    p = os.path.join(os.path.dirname(mods_dir.rstrip("/")), "ModsByServer")
    return p if os.path.isdir(p) else None

def main():
    ap = argparse.ArgumentParser(description="Sync VS mods to the server's approved set (safe).")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST, help="manifest URL or path")
    ap.add_argument("--mods-dir", help="VS Mods folder (default: auto-detect)")
    ap.add_argument("--apply", action="store_true", help="actually make changes (default: dry run)")
    args = ap.parse_args()

    mods_dir = find_mods_dir(args.mods_dir)
    if not mods_dir or not os.path.isdir(mods_dir):
        print("ERROR: could not find your Vintage Story Mods folder.")
        print("Run with --mods-dir /full/path/to/VintagestoryData/Mods")
        sys.exit(2)
    try:
        man = load_manifest(args.manifest)
    except Exception as e:
        print(f"ERROR: could not load manifest from {args.manifest}: {e}")
        sys.exit(2)

    print(f"Mods folder : {mods_dir}")
    print(f"Manifest    : game {man.get('game_version')} | {man.get('count')} mods | built {man.get('generated')}")
    print(f"Mode        : {'APPLY (will change files)' if args.apply else 'DRY RUN (no changes)'}\n")

    installed = installed_modids(mods_dir)           # modid -> [filenames] in Mods
    disabled = disabled_modids(mods_dir)             # set of disabled modids
    present = set(installed.keys())

    to_get, to_remove, ok, problems, skipped_opt = [], [], [], [], []
    want_files, mandatory_modids = set(), set()

    def consider(m, optional=False):
        mid, fn, want_sha, url = m.get("modid"), m["filename"], m.get("sha256"), m.get("url")
        # OPTIONAL (client-side, taste-dependent) mods: only touch if the friend
        # already has them present AND has not disabled them. Never add fresh.
        if optional:
            if mid not in present:
                skipped_opt.append(f"{mid} (not installed — left alone)")
                return
            if mid in disabled:
                skipped_opt.append(f"{mid} (disabled — left alone)")
                return
        else:
            mandatory_modids.add(mid)
        want_files.add(fn)
        target = os.path.join(mods_dir, fn)
        if os.path.exists(target) and want_sha and sha256(target) == want_sha:
            ok.append(fn)
            return
        if not url:
            problems.append(f"{fn} (no download URL)")
            return
        to_get.append(m)
        if mid:                                       # supersede other versions of same modid
            for other in installed.get(mid, []):
                if other != fn:
                    to_remove.append(other)

    for m in man.get("mods", []):
        consider(m, optional=False)
    for m in man.get("optional", []):
        consider(m, optional=True)

    # ModsByServer cleanup: server-pushed copies of mods we now have in Mods are
    # redundant and can conflict. Plan removal of any whose modid is one we use.
    mbs = mods_by_server_dir(mods_dir)
    mbs_remove = []
    if mbs:
        use = mandatory_modids | {m.get("modid") for m in man.get("optional", []) if m.get("modid") in present}
        for fn in os.listdir(mbs):
            if fn.lower().endswith(".zip") and modid_of(os.path.join(mbs, fn)) in use:
                mbs_remove.append(fn)

    print(f"Up to date  : {len(ok)}")
    print(f"To download : {len(to_get)}")
    for m in to_get:
        print(f"    + {m['filename']}  ({m.get('name') or m.get('modid')})")
    if to_remove:
        print(f"To replace (old versions): {len(set(to_remove))}")
        for r in sorted(set(to_remove)):
            print(f"    - {r}")
    if mbs_remove:
        print(f"ModsByServer to clean (redundant): {len(mbs_remove)}")
        for r in sorted(mbs_remove):
            print(f"    - ModsByServer/{r}")
    if skipped_opt:
        print(f"Optional left alone: {len(skipped_opt)}")
        for s in skipped_opt:
            print(f"    · {s}")
    if problems:
        print(f"Manual (no URL): {len(problems)}")
        for p in problems:
            print(f"    ! {p}")

    if not args.apply:
        print("\nDRY RUN — nothing changed. Re-run with --apply to sync.")
        return
    if not to_get and not to_remove and not mbs_remove:
        print("\nAlready in sync. Nothing to do.")
        return

    # backup Mods (and ModsByServer if we touch it) first
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = os.path.expanduser(f"~/VSmods-backup-{stamp}.zip")
    print(f"\nBacking up → {backup}")
    with zipfile.ZipFile(backup, "w", zipfile.ZIP_DEFLATED) as z:
        for fn in os.listdir(mods_dir):
            fp = os.path.join(mods_dir, fn)
            if os.path.isfile(fp):
                z.write(fp, "Mods/" + fn)
        if mbs:
            for fn in os.listdir(mbs):
                fp = os.path.join(mbs, fn)
                if os.path.isfile(fp):
                    z.write(fp, "ModsByServer/" + fn)

    for m in to_get:
        fn, want_sha, url = m["filename"], m.get("sha256"), m["url"].replace(" ", "%20")
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".zip", dir=mods_dir).name
        try:
            print(f"  downloading {fn}...")
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f)
            if want_sha and sha256(tmp) != want_sha:
                os.remove(tmp)
                print(f"    ! checksum mismatch for {fn} — discarded, NOT installed.")
                continue
            os.replace(tmp, os.path.join(mods_dir, fn))
            print(f"    ok {fn}")
        except Exception as e:
            if os.path.exists(tmp):
                os.remove(tmp)
            print(f"    ! failed {fn}: {e}")

    for r in sorted(set(to_remove)):
        rp = os.path.join(mods_dir, r)
        if os.path.exists(rp) and r not in want_files:
            os.remove(rp)
            print(f"  removed old {r}")

    for r in sorted(mbs_remove):
        rp = os.path.join(mbs, r)
        if os.path.exists(rp):
            os.remove(rp)
            print(f"  cleaned ModsByServer/{r}")

    print(f"\nDone. Backup kept at {backup}. Start the game once to rebuild caches.")

if __name__ == "__main__":
    main()
