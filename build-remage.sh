#!/usr/bin/env bash
set -euo pipefail
#
# Build remage against the locally built stack: Geant4 + thread-safe HDF5 +
# BxDecay0. Requires GEANT4_BASE, HDF5_ROOT, BXDECAY0_PREFIX.
#   chmod +x build-remage.sh && ./build-remage.sh

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

# --- preflight: Geant4, HDF5 (thread-safe C API), BxDecay0, python3 ---
: "${GEANT4_BASE:?export GEANT4_BASE first (run build-geant4.sh)}"
[[ -f "$GEANT4_BASE/lib/cmake/Geant4/Geant4Config.cmake" ]] \
  || { echo "ERROR: Geant4Config.cmake not found under $GEANT4_BASE/lib/cmake/Geant4"; exit 1; }

: "${HDF5_ROOT:?export HDF5_ROOT first (run build-hdf5.sh)}"
HDF5_DIR="${HDF5_DIR:-$HDF5_ROOT/cmake}"
[[ -d "$HDF5_DIR" ]] || { echo "ERROR: HDF5_DIR not found: $HDF5_DIR"; exit 1; }
[[ -x "$HDF5_ROOT/bin/h5cc" ]] || { echo "ERROR: h5cc not found: $HDF5_ROOT/bin/h5cc"; exit 1; }
"$HDF5_ROOT/bin/h5cc" -showconfig | grep -Ei "HDF5 Version|Threadsafety" || true

: "${BXDECAY0_PREFIX:?export BXDECAY0_PREFIX first (run build-bxdecay0.sh)}"
compgen -G "$BXDECAY0_PREFIX/lib/cmake/*/BxDecay0Config.cmake" >/dev/null \
  || echo "  WARN: BxDecay0Config.cmake not auto-found under $BXDECAY0_PREFIX/lib/cmake (CMake may still locate it)"

PY="$(command -v python3)" || { echo "ERROR: python3 required (brew install python)"; exit 1; }

WORKDIR="${REMAGE_WORKDIR:-$HOME/Documents/REMAGE}"; mkdir -p "$WORKDIR"
read -r -p "Numeric suffix for build/install dirs (optional): " SUFFIX || true
[[ -z "${SUFFIX:-}" || "$SUFFIX" =~ ^[0-9]+$ ]] || { echo "Suffix must be digits"; exit 1; }
USE_TAG=no; yesno "Checkout latest remage tag instead of main? [y/N]:" N && USE_TAG=yes

# --- clone + checkout ---
echo "[1/4] Fetch remage"
REPO="$WORKDIR/remage"
[[ -d "$REPO/.git" ]] || git clone https://github.com/legend-exp/remage.git "$REPO"
git -C "$REPO" fetch --tags --prune origin
if [[ "$USE_TAG" == yes ]]; then
  VER="$(git -C "$REPO" tag -l 'v*' --sort=version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1)"
fi
if [[ -n "${VER:-}" ]]; then
  echo "  tag $VER"
  git -C "$REPO" switch -C "release/${VER#v}" "$VER"
else
  VER=main
  git -C "$REPO" switch main && git -C "$REPO" pull --ff-only || true
fi

# --- configure ---
echo "[2/4] Configure $VER"
BUILD="$WORKDIR/build-remage-$VER${SUFFIX:+-$SUFFIX}"
PREFIX="$WORKDIR/install-remage-$VER${SUFFIX:+-$SUFFIX}"
rm -rf "$BUILD" "$PREFIX"
cmake -S "$REPO" -B "$BUILD" -G "$GEN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON \
  -DPython3_EXECUTABLE="$PY" \
  -DGeant4_DIR="$GEANT4_BASE/lib/cmake/Geant4" \
  -DHDF5_ROOT="$HDF5_ROOT" \
  -DHDF5_DIR="$HDF5_DIR" \
  -DRMG_USE_BXDECAY0=ON \
  -DRMG_USE_ROOT=OFF \
  -DRMG_BUILD_DOCS=OFF \
  -DRMG_BUILD_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_PREFIX_PATH="$HDF5_ROOT;$GEANT4_BASE;$BXDECAY0_PREFIX;/opt/homebrew"

echo "[3/4] Build + install"
build_retry "$BUILD"
cmake --install "$BUILD"
echo "  installed to $PREFIX"

# --- verify ---
echo "[4/4] Checks"
if [[ -x "$PREFIX/bin/remage" ]]; then
  "$PREFIX/bin/remage" --help >/dev/null && echo "  OK: remage runs"
else
  echo "  WARN: remage binary not found at $PREFIX/bin/remage"
fi
first="$(ls -1 "$PREFIX"/lib/*.dylib 2>/dev/null | head -n1 || true)"
[[ -n "$first" ]] && otool -L "$first" | grep -E 'Geant4|G4|hdf5|BxDecay0' || true

echo "DONE: remage $VER ready at $PREFIX"
