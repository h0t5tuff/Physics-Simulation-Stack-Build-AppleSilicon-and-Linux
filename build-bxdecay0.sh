#!/usr/bin/env bash
set -euo pipefail
#
# Build BxDecay0 with the Geant4 extension (double-beta decay generator) for
# remage. Requires GEANT4_BASE.
#   chmod +x build-bxdecay0.sh && ./build-bxdecay0.sh

yesno() { local a; read -r -p "$1 " a || true; [[ "${a:-$2}" =~ ^[Yy] ]]; }
GEN="${GENERATOR:-$(command -v ninja >/dev/null 2>&1 && echo Ninja || echo 'Unix Makefiles')}"
JOBS="$(sysctl -n hw.ncpu)"

build_retry() {
  local dir="$1" tries="${2:-5}" n=1
  until cmake --build "$dir" -j"$JOBS"; do
    (( n++ >= tries )) && { echo "Build failed after $tries attempts"; exit 1; }
    echo "  build retry $n/$tries in 10s..."; sleep 10
  done
}

# Idempotently replace a marked block in ~/.zshrc (body read from stdin).
zshrc_block() {
  local tag="$1" zrc="$HOME/.zshrc" body; body="$(cat)"
  [[ -f "$zrc" ]] || : > "$zrc"
  awk -v s="# >>> $tag >>>" -v e="# <<< $tag <<<" \
    '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$zrc" > "$zrc.tmp"
  { cat "$zrc.tmp"; printf '\n# >>> %s >>>\n%s\n# <<< %s <<<\n' "$tag" "$body" "$tag"; } > "$zrc"
  rm -f "$zrc.tmp"
}

# --- preflight: Geant4 + git-lfs ---
: "${GEANT4_BASE:?export GEANT4_BASE first (run build-geant4.sh)}"
Geant4_DIR="${Geant4_DIR:-$GEANT4_BASE/lib/cmake/Geant4}"
[[ -f "$Geant4_DIR/Geant4Config.cmake" ]] || { echo "ERROR: Geant4Config.cmake not found: $Geant4_DIR"; exit 1; }
if ! command -v git-lfs >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 && brew install git-lfs || { echo "ERROR: git-lfs required"; exit 1; }
fi
git lfs install >/dev/null 2>&1 || true

WORKDIR="${BXDECAY0_HOME:-$HOME/Documents/BXDECAY0}"; mkdir -p "$WORKDIR"
read -r -p "Numeric suffix for build/install dirs (optional): " SUFFIX || true
[[ -z "${SUFFIX:-}" || "$SUFFIX" =~ ^[0-9]+$ ]] || { echo "Suffix must be digits"; exit 1; }

# --- clone + default branch ---
echo "[1/4] Fetch BxDecay0"
REPO="$WORKDIR/bxdecay0"
[[ -d "$REPO/.git" ]] || git clone https://github.com/BxCppDev/bxdecay0.git "$REPO"
git -C "$REPO" fetch --tags --prune origin
git -C "$REPO" remote set-head origin -a >/dev/null 2>&1 || true
BRANCH="$(git -C "$REPO" symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's@^origin/@@')"
BRANCH="${BRANCH:-master}"
echo "  branch $BRANCH"
git -C "$REPO" switch "$BRANCH"
git -C "$REPO" pull --ff-only || true
git -C "$REPO" lfs pull

# --- configure + build + test + install ---
echo "[2/4] Configure"
BUILD="$WORKDIR/build${SUFFIX:+-$SUFFIX}"
PREFIX="$WORKDIR/install${SUFFIX:+-$SUFFIX}"
rm -rf "$BUILD" "$PREFIX"
cmake -S "$REPO" -B "$BUILD" -G "$GEN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=ON \
  -DBXDECAY0_WITH_GEANT4_EXTENSION=ON \
  -DBXDECAY0_INSTALL_DBD_GA_DATA=ON \
  -DGeant4_DIR="$Geant4_DIR" \
  -DCMAKE_PREFIX_PATH="$GEANT4_BASE;/opt/homebrew"

echo "[3/4] Build + test + install"
build_retry "$BUILD"
ctest --test-dir "$BUILD" --output-on-failure || echo "  WARN: some ctest cases failed"
cmake --install "$BUILD"
echo "  installed to $PREFIX"
export BXDECAY0_HOME="$WORKDIR" BXDECAY0_PREFIX="$PREFIX"

if yesno "Update ~/.zshrc BxDecay0 block -> $PREFIX? [Y/n]:" Y; then
  zshrc_block BxDecay0 <<EOF
export BXDECAY0_HOME="$WORKDIR"
export BXDECAY0_PREFIX="$PREFIX"
export PKG_CONFIG_PATH="\$BXDECAY0_PREFIX/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
EOF
  echo "  ~/.zshrc updated"
fi

echo "DONE: BxDecay0 ready at $PREFIX"
