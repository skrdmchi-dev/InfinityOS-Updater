#!/usr/bin/env bash
#
# infinity-update.sh — InfinityOS delta updater
#
# Ships preinstalled on InfinityOS. Pulls the update repo, reads manifest.json,
# and if the version is newer applies the repo contents:
#
#   extensions/  -> ~/.local/share/gnome-shell/extensions/ (+ auto-enable)
#   fonts/       -> ~/.local/share/fonts/ (+ set as GNOME default font)
#   icons/       -> ~/.icons/ (+ set as GNOME icon theme)
#   apps/        -> .deb files, installed by name (install or replace, never remove)
#   self/        -> files that overwrite this updater itself (new logic/features)
#
# Usage: ./infinity-update.sh [--dry-run] [--force] [--list] [--mark]
#
set -euo pipefail

# ---------- baked-in config ----------
REPO_URL="https://github.com/skrdmchi-dev/InfinityOS-Updater.git"
BRANCH="main"

DRY_RUN=0
FORCE=0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/infinityos-updater"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/infinityos-updater"
REPO_DIR="$CACHE_DIR/repo"
VERSION_FILE="$STATE_DIR/version"
SYSTEM_STAMP="/etc/infinityos-version"   # shipped in the ISO, marks the installed beta
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---------- helpers ----------
log()  { printf '\033[1;34m[infinity]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
run()  {
    if (( DRY_RUN )); then printf '\033[1;30m  dry-run:\033[0m %s\n' "$*"; else
        log "$*"; eval "$@"
    fi
}

usage() {
    sed -n '2,19p' "$0" | sed 's/^#\s\?//'
    exit "${1:-0}"
}

# copy that escalates to sudo if the target isn't writable
install_file() {
    local src="$1" dest="$2"
    if [[ -w "$(dirname "$dest")" ]] || { [[ -f "$dest" ]] && [[ -w "$dest" ]]; }; then
        run "cp -f '$src' '$dest'"
    else
        run "sudo cp -f '$src' '$dest'"
    fi
}

# ---------- args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)    REPO_URL="$2"; shift 2 ;;
        --branch)  BRANCH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE=1; shift ;;
        --list)    LIST_ONLY=1; shift ;;
        --mark)    MARK=1; shift ;;
        -h|--help) usage 0 ;;
        *)         die "unknown option: $1 (see --help)" ;;
    esac
done

# ---------- deps ----------
for dep in git jq dpkg-deb fc-scan; do
    command -v "$dep" >/dev/null 2>&1 && continue
    warn "missing dependency: $dep — attempting to install"
    case "$dep" in
        fc-scan) pkg=fontconfig ;;
        dpkg-deb) pkg=dpkg-dev ;;
        *) pkg="$dep" ;;
    esac
    sudo apt-get update -qq && sudo apt-get install -y "$pkg" || die "install $pkg manually"
done

# ---------- pull repo ----------
mkdir -p "$CACHE_DIR" "$STATE_DIR"

if [[ -d "$REPO_DIR/.git" ]]; then
    log "Checking for updates..."
    git -C "$REPO_DIR" fetch --quiet origin
    git -C "$REPO_DIR" checkout --quiet "$BRANCH"
    git -C "$REPO_DIR" reset --quiet --hard "origin/$BRANCH"
else
    log "Downloading $REPO_URL ..."
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

MANIFEST="$REPO_DIR/manifest.json"
[[ -f "$MANIFEST" ]] || die "repo has no manifest.json"

# ---------- version gate ----------
# Version is known three ways: the per-user stamp (written after each update),
# the ISO stamp, or --mark for people already on the current beta.
CURRENT_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || cat "$SYSTEM_STAMP" 2>/dev/null || echo none)"
REPO_VERSION="$(jq -r '.version' "$MANIFEST")"

log "Installed : $CURRENT_VERSION"
log "Repo      : $REPO_VERSION"

if [[ "${LIST_ONLY:-0}" == 1 ]]; then
    jq -r '"\(.version): \(.description // "")"' "$MANIFEST"
    exit 0
fi

if [[ "${MARK:-0}" == 1 ]]; then
    if (( DRY_RUN )); then
        printf '\033[1;30m  dry-run:\033[0m write %s to %s\n' "$REPO_VERSION" "$VERSION_FILE"
    else
        echo "$REPO_VERSION" > "$VERSION_FILE"
        log "Marked system as $REPO_VERSION — nothing applied."
    fi
    exit 0
fi

if [[ "$CURRENT_VERSION" == "$REPO_VERSION" && "$FORCE" != 1 ]]; then
    log "Already up to date."
    exit 0
fi

# ---------- self-update ----------
# Files in self/ replace this updater. Done before everything else so a new
# InfinityOS update can change how the updater works (e.g. add new folders).
shopt -s nullglob
if [[ "${INFINITY_SELF_UPDATED:-0}" != 1 ]] && [[ -d "$REPO_DIR/self" ]] \
   && [[ -n "$(ls -A "$REPO_DIR/self" 2>/dev/null)" ]]; then
    changed=0
    script_changed=0
    script_name="$(basename "${BASH_SOURCE[0]}")"
    for f in "$REPO_DIR/self"/*; do
        base="$(basename "$f")"
        dest="$SCRIPT_DIR/$base"
        if [[ -f "$dest" ]]; then
            cmp -s "$f" "$dest" && continue   # same name, same content — skip
            log "Self-update: replacing $base"
        else
            log "Self-update: installing $base"
        fi
        if (( DRY_RUN )); then
            printf '\033[1;30m  dry-run:\033[0m update %s -> %s\n' "$f" "$dest"
        else
            install_file "$f" "$dest"
        fi
        changed=1
        [[ "$base" == "$script_name" ]] && script_changed=1
    done
    # if the script itself was replaced, re-exec so the new logic applies now
    if (( changed && ! DRY_RUN )); then
        if (( script_changed )); then
            chmod +x "$SCRIPT_DIR/$script_name"
            log "Updater updated — restarting with new version..."
            args=(--repo "$REPO_URL" --branch "$BRANCH")
            (( DRY_RUN )) && args+=(--dry-run)
            (( FORCE ))   && args+=(--force)
            export INFINITY_SELF_UPDATED=1
            exec "$SCRIPT_DIR/$script_name" "${args[@]}"
        fi
    fi
fi

# ---------- extensions ----------
# Every directory in extensions/ is a GNOME extension (must contain metadata.json)
for ext in "$REPO_DIR/extensions"/*/; do
    [[ -d "$ext" ]] || continue
    [[ -f "$ext/metadata.json" ]] || { warn "skipping $ext — no metadata.json"; continue; }
    uuid="$(jq -r '.uuid' "$ext/metadata.json")"
    dest="$HOME/.local/share/gnome-shell/extensions/$uuid"
    if [[ -d "$dest" ]]; then
        # same uuid installed — replace only if contents actually differ
        if diff -qr "${ext%/}" "$dest" >/dev/null 2>&1; then
            log "Extension: $uuid already up to date — skipping"
            continue
        fi
        log "Extension: replacing $uuid"
        run "rm -rf '$dest'"
    else
        log "Extension: installing $uuid"
    fi
    run "mkdir -p '$dest' && cp -r '${ext%/}/.' '$dest/'"
    run "gnome-extensions enable '$uuid' 2>/dev/null || true"
done

# ---------- fonts ----------
# Font files go to the user font dir; the first font's family becomes the default
font_dir="$HOME/.local/share/fonts"
first_font_family=""
for f in "$REPO_DIR/fonts"/*.ttf "$REPO_DIR/fonts"/*.otf "$REPO_DIR/fonts"/*.ttc; do
    [[ -f "$f" ]] || continue
    log "Font: $(basename "$f")"
    run "mkdir -p '$font_dir' && cp '$f' '$font_dir/'"
    if [[ -z "$first_font_family" ]]; then
        first_font_family="$(fc-scan --format '%{family}\n' "$f" 2>/dev/null | head -1 | cut -d, -f1)"
    fi
done
if [[ -n "$first_font_family" ]]; then
    run "fc-cache -f '$font_dir' >/dev/null"
    log "Setting default GNOME font: $first_font_family"
    run "gsettings set org.gnome.desktop.interface font-name '$first_font_family 11'"
    run "gsettings set org.gnome.desktop.interface document-font-name '$first_font_family 11'"
fi

# ---------- icons ----------
# Every directory in icons/ is an icon theme; the last one becomes active
# (.local/share/icons is the XDG path — GTK4/libadwaita apps ignore ~/.icons)
for theme in "$REPO_DIR/icons"/*/; do
    [[ -d "$theme" ]] || continue
    name="$(basename "${theme%/}")"
    log "Icon theme: $name"
    run "mkdir -p '$HOME/.local/share/icons' && cp -r '${theme%/}' '$HOME/.local/share/icons/$name'"
    run "gsettings set org.gnome.desktop.interface icon-theme '$name'"
done
if [[ -d "$HOME/.local/share/icons" ]]; then
    run "gtk-update-icon-cache -q '$HOME/.local/share/icons'/* 2>/dev/null || true"
fi

# ---------- apps ----------
# Each .deb is matched by package name: installed? -> replace. Missing? -> install.
# Apps already on the system that aren't in the repo are never touched.
for deb in "$REPO_DIR/apps"/*.deb; do
    [[ -f "$deb" ]] || continue
    pkg="$(dpkg-deb -f "$deb" Package)"
    ver="$(dpkg-deb -f "$deb" Version)"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        installed_ver="$(dpkg -s "$pkg" | awk -F': ' '/^Version/ {print $2}')"
        if [[ "$installed_ver" == "$ver" ]]; then
            log "App: $pkg already at $ver — skipping"
            continue
        fi
        log "App: replacing $pkg ($installed_ver -> $ver)"
    else
        log "App: installing $pkg $ver"
    fi
    run "sudo apt-get install -y '$deb'"
done

# ---------- done ----------
if (( DRY_RUN )); then
    log "Dry run complete — nothing was changed."
else
    echo "$REPO_VERSION" > "$VERSION_FILE"
    log "Done. System updated to $REPO_VERSION."
    warn "Log out and back in for extension changes to fully apply."
fi
