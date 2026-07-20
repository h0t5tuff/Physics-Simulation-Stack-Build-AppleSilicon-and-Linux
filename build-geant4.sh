#!/usr/bin/env bash
set -euo pipefail
#
# Build Geant4 (latest stable) with MT, GDML and Qt/OpenGL vis.
#   chmod +x build-geant4.sh && ./build-geant4.sh

yesno() { local a; read -r -p "$1 " a || true; [[ "${a:-$2}" =~ ^[Yy] ]]; }
GEN="${GENERATOR:-$(command -v ninja >/dev/null 2>&1 && echo Ninja || echo 'Unix Makefiles')}"
JOBS="$(sysctl -n hw.ncpu)"

# cmake --build with retries (Geant4 downloads datasets — network can be flaky).
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

# --- preflight: optional Homebrew deps ---
if command -v brew >/dev/null 2>&1 && yesno "Install/verify Homebrew build deps? [y/N]:" N; then
  brew update && brew install cmake ninja pkgconf git wget expat xerces-c qt python make \
    libx11 clhep jpeg libxi libxmu open-mpi || true
fi

WORKDIR="${GEANT4_WORKDIR:-$HOME/Documents/GEANT4}"; mkdir -p "$WORKDIR"
read -r -p "Numeric suffix for build/install dirs (optional): " SUFFIX || true
[[ -z "${SUFFIX:-}" || "$SUFFIX" =~ ^[0-9]+$ ]] || { echo "Suffix must be digits"; exit 1; }

# --- clone + latest stable tag ---
echo "[1/4] Fetch Geant4"
REPO="$WORKDIR/geant4"
[[ -d "$REPO/.git" ]] || git clone https://github.com/Geant4/geant4.git "$REPO"
git -C "$REPO" fetch --tags --prune origin
VER="$(git -C "$REPO" tag -l 'v*' --sort=version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1)"
[[ -n "$VER" ]] || { echo "ERROR: no stable tag found"; exit 1; }
echo "  $VER"
git -C "$REPO" switch -C "release/${VER#v}" "$VER"

# --- configure ---
echo "[2/4] Configure $VER"
BUILD="$WORKDIR/build-$VER${SUFFIX:+-$SUFFIX}"
PREFIX="$WORKDIR/install-$VER${SUFFIX:+-$SUFFIX}"
rm -rf "$BUILD" "$PREFIX"
cmake -S "$REPO" -B "$BUILD" -G "$GEN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DGEANT4_BUILD_MULTITHREADED=ON \
  -DGEANT4_INSTALL_DATA=ON \
  -DGEANT4_INSTALL_EXAMPLES=ON \
  -DGEANT4_USE_SYSTEM_EXPAT=ON \
  -DGEANT4_USE_GDML=ON \
  -DGEANT4_USE_QT=ON \
  -DGEANT4_USE_OPENGL=ON \
  -DCMAKE_PREFIX_PATH="/opt/homebrew"

echo "[3/4] Build + install"
build_retry "$BUILD"
cmake --install "$BUILD"
echo "  installed to $PREFIX"
export GEANT4_BASE="$PREFIX" Geant4_DIR="$PREFIX/lib/cmake/Geant4"

if yesno "Update ~/.zshrc Geant4 block -> $PREFIX? [Y/n]:" Y; then
  zshrc_block Geant4 <<EOF
export GEANT4_BASE="$PREFIX"
[[ -f "\$GEANT4_BASE/bin/geant4.sh" ]] && source "\$GEANT4_BASE/bin/geant4.sh"
export Geant4_DIR="\$GEANT4_BASE/lib/cmake/Geant4"
path=("\$GEANT4_BASE/bin" \$path)
export G4VIS_DEFAULT_DRIVER=OGLSQt
EOF
  echo "  ~/.zshrc updated"
fi

# --- verify: find_package(Geant4) + G4analysis links ---
echo "[4/4] CMake link test"
T="$(mktemp -d)"
cat > "$T/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(g4test CXX)
find_package(Geant4 REQUIRED)
add_executable(g4test main.cc)
target_link_libraries(g4test PRIVATE Geant4::G4analysis)
EOF
printf '#include "G4Version.hh"\n#include <iostream>\nint main(){std::cout<<G4VERSION_NUMBER<<"\\n";}\n' > "$T/main.cc"
cmake -S "$T" -B "$T/build" -G "$GEN" \
  -DGeant4_DIR="$PREFIX/lib/cmake/Geant4" -DCMAKE_PREFIX_PATH="/opt/homebrew"
cmake --build "$T/build" -j"$JOBS"
otool -L "$T/build/g4test" | grep -E 'G4analysis|G4' || true
rm -rf "$T"

echo "DONE: Geant4 $VER ready at $PREFIX"
