#!/bin/bash
# Anaconda Uninstall Script for Iru MDM
# Removes Anaconda/Miniconda/Miniforge/Mambaforge — system-wide and per-user.
# Runs as root via Kandji.
# Set DRY_RUN=1 to preview without making changes.
# Exit 0 = clean (nothing left). Exit 1 = artifacts remain after cleanup.

set -u
DRY_RUN=1
LOG_PREFIX="[anaconda-uninstall]"

log()  { echo "$LOG_PREFIX $*"; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then log "DRY-RUN: $*"; else log "EXEC: $*"; "$@"; fi; }

remove_path() {
    local p="$1"
    [[ -e "$p" || -L "$p" ]] || return 0
    run rm -rf -- "$p"
}

# Safety: only ever delete paths whose name clearly belongs to a conda distribution.
# Note: "continuum" alone is NOT matched here — it collides with BorisFX Continuum.
# Only the literal hidden user dir ".continuum" (Anaconda's) is treated as conda.
is_conda_path() {
    case "$1" in
        *anaconda*|*Anaconda*|*miniconda*|*Miniconda*|*miniforge*|*Miniforge*|*mambaforge*|*Mambaforge*) return 0 ;;
        */.continuum|*/.continuum/*) return 0 ;;
    esac
    return 1
}

# Anaconda's pkg receipts use com.continuum.* or com.anaconda.* — anchor to those vendors.
# Explicitly excludes com.borisfx.* (BorisFX Continuum video plugins).
CONDA_PKG_REGEX='^(com\.continuum\.|com\.anaconda\.)|anaconda|miniconda|miniforge|mambaforge'

# 1. Pkg receipts — remove install root, then forget the receipt
while IFS= read -r pkg_id; do
    [[ -z "$pkg_id" ]] && continue
    # Defense-in-depth: never touch BorisFX or other unrelated vendors
    [[ "$pkg_id" == com.borisfx.* ]] && continue
    log "Found pkg receipt: $pkg_id"

    info=$(pkgutil --pkg-info "$pkg_id" 2>/dev/null)
    volume=$(awk -F': ' '/^volume:/ {print $2}' <<<"$info")
    location=$(awk -F': ' '/^location:/ {print $2}' <<<"$info")
    install_root="${volume%/}/${location#/}"
    install_root="${install_root%/}"

    if [[ -n "$install_root" && "$install_root" != "/" && -d "$install_root" ]] \
       && is_conda_path "$install_root"; then
        remove_path "$install_root"
    fi

    run pkgutil --forget "$pkg_id"
done < <(pkgutil --pkgs 2>/dev/null | grep -iE "$CONDA_PKG_REGEX" | grep -v '^com\.borisfx\.')

# 2. System-wide install directories
SYSTEM_DIRS=(
    /opt/anaconda3 /opt/anaconda /opt/miniconda3 /opt/miniconda
    /opt/miniforge3 /opt/mambaforge
    /usr/local/anaconda3 /usr/local/miniconda3
    /Applications/anaconda3
    /Applications/Anaconda-Navigator.app
    /opt/homebrew/anaconda3 /opt/homebrew/miniconda3
    /opt/homebrew/Caskroom/anaconda /opt/homebrew/Caskroom/miniconda
    /opt/homebrew/Caskroom/miniforge /opt/homebrew/Caskroom/mambaforge
    /usr/local/Caskroom/anaconda /usr/local/Caskroom/miniconda
    /usr/local/Caskroom/miniforge /usr/local/Caskroom/mambaforge
)
for dir in "${SYSTEM_DIRS[@]}"; do
    remove_path "$dir"
done

# Homebrew bin symlinks — only if they point at conda
for sym in /opt/homebrew/bin/conda /usr/local/bin/conda; do
    if [[ -L "$sym" ]]; then
        target=$(readlink "$sym")
        is_conda_path "$target" && remove_path "$sym"
    fi
done

# Homebrew casks — uninstall as the console user (brew refuses to run as root)
console_user=$(stat -f%Su /dev/console 2>/dev/null)
if [[ -n "$console_user" && "$console_user" != "root" ]]; then
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$brew_bin" ]] || continue
        for cask in anaconda miniconda miniforge mambaforge; do
            if sudo -u "$console_user" "$brew_bin" list --cask "$cask" >/dev/null 2>&1; then
                log "Uninstalling Homebrew cask: $cask"
                run sudo -u "$console_user" "$brew_bin" uninstall --cask --force "$cask"
            fi
        done
    done
fi

# Helper: strip conda/mamba init blocks from a shell rc file (with one-time backup)
strip_init_block() {
    local file="$1" marker_open="$2" marker_close="$3"
    [[ -f "$file" ]] || return 0
    grep -q "$marker_open" "$file" 2>/dev/null || return 0
    log "Stripping init block ($marker_open) from $file"
    if [[ "$DRY_RUN" != "1" ]]; then
        [[ -f "${file}.preanaconda-uninstall" ]] || cp -p "$file" "${file}.preanaconda-uninstall"
        /usr/bin/sed -i '' -e "/$marker_open/,/$marker_close/d" "$file"
    fi
}

# 3. Per-user cleanup
while IFS= read -r username; do
    user_home=$(dscl . read /Users/"$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [[ -d "$user_home" ]] || continue
    log "Cleaning user: $username ($user_home)"

    USER_DIRS=(
        "$user_home/anaconda3" "$user_home/anaconda"
        "$user_home/miniconda3" "$user_home/miniconda"
        "$user_home/miniforge3" "$user_home/mambaforge"
        "$user_home/opt/anaconda3" "$user_home/opt/miniconda3"
        "$user_home/opt/miniforge3" "$user_home/opt/mambaforge"
        "$user_home/Applications/Anaconda-Navigator.app"
        "$user_home/.conda" "$user_home/.condarc"
        "$user_home/.continuum" "$user_home/.anaconda"
    )
    for dir in "${USER_DIRS[@]}"; do
        remove_path "$dir"
    done

    # pyenv- and asdf-managed conda installs
    for base in "$user_home/.pyenv/versions" "$user_home/.asdf/installs/python"; do
        [[ -d "$base" ]] || continue
        while IFS= read -r v; do
            [[ -n "$v" ]] && remove_path "$v"
        done < <(find "$base" -mindepth 1 -maxdepth 1 -type d \
                    \( -iname 'anaconda*' -o -iname 'miniconda*' -o -iname 'miniforge*' -o -iname 'mambaforge*' \) 2>/dev/null)
    done

    # Shell init blocks
    for rc in .bashrc .bash_profile .zshrc .zprofile .profile .config/fish/config.fish; do
        strip_init_block "$user_home/$rc" '# >>> conda initialize >>>' '# <<< conda initialize <<<'
        strip_init_block "$user_home/$rc" '# >>> mamba initialize >>>' '# <<< mamba initialize <<<'
    done
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

# 4. Spotlight catch-all for any custom-location installs we missed
while IFS= read -r meta_dir; do
    [[ -z "$meta_dir" ]] && continue
    install_root="${meta_dir%/conda-meta}"
    [[ "$install_root" == *"/envs/"* ]] && continue
    [[ -z "$install_root" || "$install_root" == "/" ]] && continue
    is_conda_path "$install_root" || continue   # extra safety on non-standard paths
    log "Spotlight match — removing $install_root"
    remove_path "$install_root"
done < <(mdfind "kMDItemFSName == 'conda-meta'" 2>/dev/null)

# 5. Verify
log "Verifying..."
REMAINING=()
while IFS= read -r pkg_id; do
    [[ -n "$pkg_id" ]] && REMAINING+=("pkg receipt still present: $pkg_id")
done < <(pkgutil --pkgs 2>/dev/null | grep -iE "$CONDA_PKG_REGEX" | grep -v '^com\.borisfx\.')

while IFS= read -r meta_dir; do
    [[ -z "$meta_dir" ]] && continue
    install_root="${meta_dir%/conda-meta}"
    [[ "$install_root" == *"/envs/"* ]] && continue
    REMAINING+=("$install_root")
done < <(mdfind "kMDItemFSName == 'conda-meta'" 2>/dev/null)

if [[ ${#REMAINING[@]} -eq 0 ]]; then
    log "Anaconda removal complete."
    exit 0
else
    log "Anaconda artifacts still present after cleanup:"
    printf '  - %s\n' "${REMAINING[@]}"
    exit 1
fi
