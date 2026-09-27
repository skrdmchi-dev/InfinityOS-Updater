# InfinityOS Updater

Turns new InfinityOS betas into a **delta update** instead of an ISO
reinstall. Drop what changed into the folders below, bump `manifest.json`,
push — and users run `./infinity-update.sh` to upgrade in place.

## Repo layout

```
infinityos-repo/
├── infinity-update.sh   # the script users run (repo URL baked in)
├── manifest.json        # {"version": "beta3", "description": "..."}
├── extensions/          # one dir per GNOME extension (with metadata.json)
├── fonts/               # .ttf / .otf / .ttc files
├── icons/               # one dir per icon theme (with index.theme)
├── apps/                # .deb packages
└── self/                # files that overwrite the updater itself
```

## What each folder does

| Folder        | Behavior |
|---------------|----------|
| `extensions/` | Each subdirectory is matched by **uuid** (from `metadata.json`): missing → installed to `~/.local/share/gnome-shell/extensions/`; present but different → replaced; identical → skipped. Then auto-enabled. |
| `fonts/`      | Font files are installed to `~/.local/share/fonts/`, cache rebuilt, and the first font's family is set as the GNOME interface + document font. |
| `icons/`      | Each subdirectory is installed to `~/.icons/<name>/` and set as the active GNOME icon theme. |
| `apps/`       | Each `.deb` is matched by **package name**: not installed → installed; installed at a different version → replaced. Apps already on the system that aren't in the repo are **never removed**. Same version → skipped. |
| `self/`       | Files matched by **filename**: missing → installed next to the running script; present but different → replaced; identical → skipped. If the script itself changed it re-execs so new logic applies immediately — this is how you ship new folder types/features in the future. |

`manifest.json` is just a version gate:

```json
{ "version": "beta3", "description": "new icons and apps" }
```

If the user's stored version (`~/.local/state/infinityos-updater/version`)
already equals the manifest version, nothing is applied unless `--force`.

## Usage

```bash
./infinity-update.sh            # pull repo, compare version, apply
./infinity-update.sh --dry-run  # print every action, change nothing
./infinity-update.sh --list     # show repo version/description, exit
./infinity-update.sh --force    # re-apply even if version matches
```

The repo URL is hardcoded in the script (`REPO_URL` at the top) — set it once
before shipping the ISO. `--repo`/`--branch` exist for testing forks.

## Workflow when a new beta drops

1. Boot the new ISO in a VM.
2. Diff vs the previous beta:
   - `ls /usr/share/gnome-shell/extensions ~/.local/share/gnome-shell/extensions` → copy new/changed extension dirs into `extensions/`
   - `/usr/share/fonts`, `fc-list` → copy new font files into `fonts/`
   - `/usr/share/icons` → copy new/changed icon theme dirs into `icons/`
   - `dpkg -l` → export updated apps as `.deb`s into `apps/` (`apt download <pkg>`)
3. Bump `version` in `manifest.json`, commit, push.
4. Users run `./infinity-update.sh`.

## Shipping the updater in the ISO

Install `infinity-update.sh` somewhere on PATH (e.g. `/usr/local/bin/`).
If it's in a root-owned location, `self/` updates will use sudo automatically.

## Caveats

- Extension dirs **must** contain `metadata.json` with a `uuid` field.
- Shell extensions may need a GNOME restart (log out/in on Wayland) before
  enabling sticks.
- `apps/` expects `.deb` files — for Flatpaks/Snaps you'd add a new folder
  type and ship the handling code via `self/`.
- Keep the repo public, or give users a read-only deploy key.
