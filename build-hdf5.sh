#!/usr/bin/env bash
set -euo pipefail
#
# Build thread-safe HDF5 (latest stable) — the foundation of the Geant4/remage
# stack. Patches h5cc to support `-show` (needed by CMake's module-mode
# FindHDF5) and verifies with a find_package(HDF5) test.
#   chmod +x build-hdf5.sh && ./build-hdf5.sh
#
# Note: C++ libs stay OFF — they are mutually exclusive with THREADSAFE=ON,
# which Geant4-MT requires. remage uses only the HDF5 C API.

yesno() { local a; read -r -p "$1 " a || true; [[ "${a:-$2}" =~ ^[Yy] ]]; }
GEN="${GENERATOR:-$(command -v ninja >/dev/null 2>&1 && echo Ninja || echo 'Unix Makefiles')}"
JOBS="$(sysctl -n hw.ncpu)"

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
  brew update && brew install cmake ninja pkgconf git wget python make || true
fi

WORKDIR="${HDF5_WORKDIR:-$HOME/Documents/HDF5}"; mkdir -p "$WORKDIR"
read -r -p "Numeric suffix for build/install dirs (optional): " SUFFIX || true
[[ -z "${SUFFIX:-}" || "$SUFFIX" =~ ^[0-9]+$ ]] || { echo "Suffix must be digits"; exit 1; }

# --- clone + latest stable tag ---
echo "[1/5] Fetch HDF5"
REPO="$WORKDIR/hdf5"
[[ -d "$REPO/.git" ]] || git clone https://github.com/HDFGroup/hdf5.git "$REPO"
git -C "$REPO" fetch --tags --prune origin
# HDF Group's current tag scheme is hdf5_X.Y.Z[.W] (underscore + dots); the older
# hdf5-1_X_Y form is frozen at 1.14.3. Match the new scheme and take the highest
# stable version (excludes -rc/-pre/snapshot/etc.), so this tracks 2.x and beyond.
VER="$(git -C "$REPO" tag -l 'hdf5_*' | grep -E '^hdf5_[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -n1)"
[[ -n "$VER" ]] || { echo "ERROR: no stable release tag found"; exit 1; }
echo "  $VER"
git -C "$REPO" switch -C "release/$VER" "$VER"

# --- configure + build + install ---
echo "[2/5] Build + install $VER"
BUILD="$WORKDIR/build-$VER${SUFFIX:+-$SUFFIX}"
PREFIX="$WORKDIR/install-$VER${SUFFIX:+-$SUFFIX}"
rm -rf "$BUILD" "$PREFIX"
cmake -S "$REPO" -B "$BUILD" -G "$GEN" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DHDF5_ENABLE_THREADSAFE=ON \
  -DHDF5_BUILD_HL_LIB=OFF \
  -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_BUILD_FORTRAN=OFF \
  -DHDF5_BUILD_JAVA=OFF \
  -DBUILD_TESTING=OFF
cmake --build "$BUILD" -j"$JOBS"
cmake --install "$BUILD"
echo "  installed to $PREFIX"

# --- patch h5cc so CMake's FindHDF5 can probe it with `-show` ---
echo "[3/5] Patch h5cc"
H5CC="$PREFIX/bin/h5cc"
[[ -x "$H5CC" ]] || { echo "ERROR: $H5CC missing"; exit 1; }
[[ -f "$PREFIX/lib/libhdf5.settings" ]] || { echo "ERROR: $PREFIX/lib/libhdf5.settings missing"; exit 1; }
[[ -e "$PREFIX/bin/h5cc.real" ]] || mv "$H5CC" "$PREFIX/bin/h5cc.real"
cat > "$H5CC" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
export PKG_CONFIG_PATH="$dir/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
case "${1:-}" in
  -showconfig) cat "$dir/lib/libhdf5.settings" ;;
  -show)       echo "/usr/bin/cc $(pkg-config --define-variable=prefix="$dir" --cflags --libs hdf5)" ;;
  *)           exec /usr/bin/cc "$@" $(pkg-config --define-variable=prefix="$dir" --cflags --libs hdf5) ;;
esac
EOF
chmod +x "$H5CC"
"$H5CC" -show | head -n1

# --- config-mode FindHDF5 aliases ---
echo "[4/5] Add HDF5Config.cmake aliases"
CMK="$PREFIX/cmake"
if [[ -d "$CMK" ]]; then
  ln -sf "$CMK/hdf5-config.cmake"         "$CMK/HDF5Config.cmake"
  ln -sf "$CMK/hdf5-config-version.cmake" "$CMK/HDF5ConfigVersion.cmake"
fi

if yesno "Update ~/.zshrc HDF5 block -> $PREFIX? [Y/n]:" Y; then
  zshrc_block HDF5 <<EOF
export HDF5_ROOT="$PREFIX"
export HDF5_DIR="\$HDF5_ROOT/cmake"
path=("\$HDF5_ROOT/bin" \$path)
export PKG_CONFIG_PATH="\$HDF5_ROOT/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
EOF
  echo "  ~/.zshrc updated"
fi
export HDF5_ROOT="$PREFIX" HDF5_DIR="$PREFIX/cmake"

# --- verify with find_package(HDF5) ---
echo "[5/5] CMake find test"
T="$(mktemp -d)"
cat > "$T/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(hdf5test C)
set(CMAKE_FIND_PACKAGE_PREFER_CONFIG ON)
find_package(HDF5 REQUIRED CONFIG)
add_executable(hdf5test main.c)
# Config-package target name varies by version (bare hdf5-shared in 1.x; may be
# namespaced hdf5::hdf5-shared in 2.x). Link whichever this install exports.
if(TARGET hdf5::hdf5-shared)
  target_link_libraries(hdf5test PRIVATE hdf5::hdf5-shared)
elseif(TARGET hdf5-shared)
  target_link_libraries(hdf5test PRIVATE hdf5-shared)
else()
  target_link_libraries(hdf5test PRIVATE ${HDF5_C_LIBRARIES} ${HDF5_LIBRARIES})
endif()
EOF
printf '#include "hdf5.h"\n#include <stdio.h>\nint main(void){printf("HDF5 %s\\n",H5_VERSION);}\n' > "$T/main.c"
cmake -S "$T" -B "$T/build" -G "$GEN" -DHDF5_DIR="$PREFIX/cmake" -DCMAKE_PREFIX_PATH="$PREFIX;/opt/homebrew"
cmake --build "$T/build" -j"$JOBS"
"$T/build/hdf5test" || true
rm -rf "$T"

echo "DONE: HDF5 $VER ready at $PREFIX"
