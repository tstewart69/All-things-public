#!/bin/bash
# Anaconda Audit Script for Iru MDM
# Exit 0 = compliant (not installed)
# Exit 1 = non-compliant (installed) — prints location(s)
# Runs as root via Kandji

FOUND=()

add_finding() {
    FOUND+=("$1")
}

# 1. pkg receipts (Anaconda .pkg installer)
while IFS= read -r pkg_id; do
    [[ -z "$pkg_id" ]] && continue
    install_loc=$(pkgutil --pkg-info "$pkg_id" 2>/dev/null | awk -F': ' '/^volume:/ {v=$2} /^location:/ {l=$2} END {print v l}')
    add_finding "pkg receipt: ${pkg_id} (installed at: ${install_loc:-unknown})"
done < <(pkgutil --pkgs 2>/dev/null | grep -iE '(anaconda|continuum|miniconda|miniforge|mambaforge)')

# 2. System-wide install directories
SYSTEM_DIRS=(
    /opt/anaconda3 /opt/anaconda /opt/miniconda3 /opt/miniconda
    /opt/miniforge3 /opt/mambaforge
    /usr/local/anaconda3 /usr/local/miniconda3
    /Applications/anaconda3
    /Applications/Anaconda-Navigator.app
    # Homebrew cask install locations (Apple Silicon + Intel)
    /opt/homebrew/anaconda3 /opt/homebrew/miniconda3
    /opt/homebrew/Caskroom/anaconda /opt/homebrew/Caskroom/miniconda
    /opt/homebrew/Caskroom/miniforge /opt/homebrew/Caskroom/mambaforge
    /usr/local/Caskroom/anaconda /usr/local/Caskroom/miniconda
    /usr/local/Caskroom/miniforge /usr/local/Caskroom/mambaforge
    # Homebrew formula symlinks
    /opt/homebrew/bin/conda /usr/local/bin/conda
)

for dir in "${SYSTEM_DIRS[@]}"; do
    [[ -e "$dir" ]] && add_finding "$dir"
done

# 3. Per-user install directories
while IFS= read -r username; do
    user_home=$(dscl . read /Users/"$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [[ -d "$user_home" ]] || continue

    USER_DIRS=(
        "$user_home/anaconda3" "$user_home/anaconda"
        "$user_home/miniconda3" "$user_home/miniconda"
        "$user_home/miniforge3" "$user_home/mambaforge"
        "$user_home/opt/anaconda3" "$user_home/opt/miniconda3"
        "$user_home/opt/miniforge3" "$user_home/opt/mambaforge"
        "$user_home/Applications/Anaconda-Navigator.app"
    )
    for dir in "${USER_DIRS[@]}"; do
        [[ -e "$dir" ]] && add_finding "$dir"
    done

    # pyenv-managed conda installs
    if [[ -d "$user_home/.pyenv/versions" ]]; then
        while IFS= read -r v; do
            [[ -n "$v" ]] && add_finding "$v"
        done < <(find "$user_home/.pyenv/versions" -mindepth 1 -maxdepth 1 -type d \
                    \( -iname 'anaconda*' -o -iname 'miniconda*' -o -iname 'miniforge*' -o -iname 'mambaforge*' \) 2>/dev/null)
    fi

    # asdf-managed conda installs
    if [[ -d "$user_home/.asdf/installs/python" ]]; then
        while IFS= read -r v; do
            [[ -n "$v" ]] && add_finding "$v"
        done < <(find "$user_home/.asdf/installs/python" -mindepth 1 -maxdepth 1 -type d \
                    \( -iname 'anaconda*' -o -iname 'miniconda*' -o -iname 'miniforge*' -o -iname 'mambaforge*' \) 2>/dev/null)
    fi
done < <(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1}')

# 4. Spotlight catch-all — every conda install has a `conda-meta` directory at its root.
#    Filters paths already known to Spotlight; covers custom install locations the .sh installer allowed.
while IFS= read -r meta_dir; do
    [[ -z "$meta_dir" ]] && continue
    # Parent dir is the install root
    install_root="${meta_dir%/conda-meta}"
    # Skip if it's an env inside an already-reported install (envs/<name>/conda-meta)
    [[ "$install_root" == *"/envs/"* ]] && continue
    add_finding "$install_root  (via Spotlight)"
done < <(mdfind "kMDItemFSName == 'conda-meta'" 2>/dev/null)

# Result — dedupe and report
if [[ ${#FOUND[@]} -eq 0 ]]; then
    echo "Anaconda not detected."
    exit 0
else
    echo "Anaconda detected. Locations:"
    printf '%s\n' "${FOUND[@]}" | awk '!seen[$0]++' | sed 's/^/  - /'
    exit 1
fi
