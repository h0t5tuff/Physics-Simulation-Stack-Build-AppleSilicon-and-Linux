# Physics Simulation Stack — Build Scripts (Apple Silicon & Linux)

From-source build chain for the **LEGEND** simulation software:
**Geant4 → BxDecay0 → remage**.

The scripts give one reproducible, CMake-discoverable toolchain that
won't collide with system or Homebrew installs. Primary target is macOS (Apple
Silicon); Linux notes appear in the examples at the bottom.

## Why from source

remage needs a consistent dependency chain. Mixing system/Homebrew libraries
causes silent ABI and threading failures. These three scripts build the whole
stack the same way every time.

## The scripts

| # | Script | Builds | Requires (env in) |
|---|--------|--------|-------------------|
| 1 | [`build-geant4.sh`](build-geant4.sh) | Geant4 latest stable — MT, GDML, Qt/OpenGL vis, datasets | — |
| 2 | [`build-bxdecay0.sh`](build-bxdecay0.sh) | BxDecay0 with the Geant4 extension (double-beta generator) | `GEANT4_BASE` |
| 3 | [`build-remage.sh`](build-remage.sh) | remage — links Geant4 + BxDecay0 (ROOT off) | `GEANT4_BASE`, `BXDECAY0_PREFIX` |

Each script: picks **Ninja** if present (else Unix Makefiles), prompts for an
optional numeric **suffix** so multiple builds can live side by side, and offers
to write a marked block to `~/.zshrc` exporting the env var the next stage needs.

> **Note:** this chain builds no HDF5, so Geant4 is configured without HDF5
> analysis and remage is built **without LH5 output support**. remage will abort
> at output time with `HDF5 and LH5 support is not available!`.

## Usage (order matters)

```bash
chmod +x build-*.sh

./build-geant4.sh     # exports GEANT4_BASE
source ~/.zshrc

./build-bxdecay0.sh   # exports BXDECAY0_PREFIX
source ~/.zshrc

./build-remage.sh
```

Each stage's env vars feed the next, so **re-source `~/.zshrc` (or open a new
shell) between stages.**

**Default work dirs** (override with the env var in parentheses):

| Stage | Location | Override |
|-------|----------|----------|
| Geant4 | `~/Documents/GEANT4` | `GEANT4_WORKDIR` |
| BxDecay0 | `~/Documents/BXDECAY0` | `BXDECAY0_HOME` |
| remage | `~/Documents/REMAGE` | `REMAGE_WORKDIR` |

Override the build tool with `GENERATOR`. Each script ends with a self-test
(`find_package` + link/`otool` check) so a stage fails loudly, not later.

## Dependency stack

```
remage      ▲   LEGEND simulation layer
BxDecay0    │   double-beta decay generator
Geant4      │   MT, GDML, Qt/OpenGL
```

ROOT (via Homebrew) is **optional** — not needed by the four-script chain, but
used by some examples below (`bacon2Data`, `BACONCalibrationSimulation`).

---

# Examples & run notes

Working notes for running simulations on top of this stack. Paths, branches, and
line numbers are reproduced as-is from the author's setup — adjust to yours.

## ROOT

### bacon2Data

**Build**

```bash
git clone --branch runTwo https://github.com/liebercanis/bacon2Data.git
cd bacon2Data && git pull
# hard reset alternative:
# git fetch origin && git reset --hard origin/runTwo && git clean -fdx
```

**Create symlink** (in `bobj`)

```bash
cd bobj
# macOS:
ln -s /opt/homebrew/opt/root/etc/root/Makefile.arch .
# Linux:
ln -s /snap/root-framework/current/usr/local/etc/Makefile.arch .
```

**Hard-code path** if you're not cloning in your home dir — edit `bobj/makefile`:

```make
INSTALLNAME  :=  $(HOME)/ROOT/bacon2Data/bobj/$(LIBRARY)
```

**Build**

```bash
make clean; make
cd ../compiled && make clean; make
```

**Create data dirs** and put `btbSim` / `anacg` files there:

```bash
# macOS (in compiled):
mkdir caenData
mkdir rootData
# Linux (in compiled and in bacon2Data):
ln -s /mnt/Data2/BaconRun5Data/rootData/ rootData
ln -s /mnt/Data2/BaconRun4Data/caenData/ caenData
ln -s /home/gold/bacon2Data/compiled/ compiledGold
ln -s /home/gold/bacon2Data/bobj/ bobjGold
```

**Gains files** — put in `bobj`, then symlink in place so `postAna` uses them:

```bash
ln -s <gainPeak root file> gainPeakCurrent.root
ln -s <gainSum root file> gainSumCurrent.root
```

**Run executables**

```bash
# macOS:
cd compiled
btbSim <events number>            # then copy root file to /rootData
anacg <root file from btbSim>     # product root file lives in /caenData
postAna <etag> <etag> <max entries>
#   first put a summary/post root file in /compiled,
#   then set that filename in gain.C & gainSum.C (ln288)

# Linux:
cd bacon2Data
nohup ./anacDir.py 00_00_0000 >& anacDir00_00_0000.log &
top
```

### BaconMonitor

```bash
# macOS:
xhost +SI:localuser:root

# on daq (via ssh):
ln -s /home/bacon/BaconMonitor/BaconMonitor2_tensor.py /home/Tensor/BaconMonitor2_tensor.py
sudo visudo
#   Tensor ALL=(ALL) NOPASSWD: SETENV: /usr/bin/python3 /home/Tensor/BaconMonitor2_tensor.py
```

## Geant4

### BACONCalibrationSimulation — debugging log

A successful problem-solving session getting Alex's sim running: header scoping
fixes, STL path handling, env-based ROOT path flexibility, and final launch.

**1. Geant4 header scoping — `G4Track` undefined** (`unknown type name 'G4Track'`)

Recent Geant4 requires explicit class headers; forward declarations and umbrella
includes are no longer sufficient. Fix — forward declare in the header
`HistoManager.hh`, include the real header in `HistoManager.cc`:

```cpp
// HistoManager.hh
class G4Track;

// HistoManager.cc
#include "G4Track.hh"
```

**2. STL rejected — CADMesh expects ASCII** (error near line 1: STL must start with `solid`)

First suspected a binary (not ASCII) STL, or a wrong path. Sanity checks:

```bash
# file header:
head -n 5 source_holder_assembly_axes_aligned_simplified_coursemeshcombined_v20250521.STL | cat -vet
# file tail:
tail -n 10 source_holder_assembly_axes_aligned_simplified_coursemeshcombined_v20250521.STL | cat -vet
# non-printable (binary) rubbish:
grep -a -o '[^[:print:][:space:]]' source_holder_assembly_axes_aligned_simplified_coursemeshcombined_v20250521.STL | head
```

Nothing weird came out → the STL was valid ASCII. The error persisted because the
**path was wrong**: the file didn't exist at runtime, so CADMesh read a
non-existent/empty file and (correctly) errored with "STL files start with 'solid'".

```bash
# wrong (does not exist):
ls -l ../BACONCalibrationSimulation/STLFiles/source_holder_assembly_axes_aligned_simplified_coursemeshcombined_v20250521.STL
# -> ls: ...: No such file or directory

# correct path:
ls -l ../STLFiles/source_holder_assembly_axes_aligned_simplified_coursemeshcombined_v20250521.STL
```

Fix — updated the path in `DetectorConstruction.cc:199`:

```cpp
auto BasePlateMesh = CADMesh::TessellatedMesh::FromSTL(fSourceHolderFilePath);
```

Then created a folder with a symlink so the expected path resolves:

```bash
cd BACONCalibrationSimulation
mkdir -p BACONCalibrationSimulation
ln -s ../STLFiles BACONCalibrationSimulation/STLFiles
```

Finally, adjusted the ROOT-file paths in all macros, and removed anything saying
`shard` in `CMakeLists.txt` (there is no `shared` folder).

**Build**

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DWITH_GEANT4_UIVIS=ON \
  -DCMAKE_PREFIX_PATH="$(geant4-config --prefix);$ROOT_DIR"
cmake --build build -j"$(sysctl -n hw.ncpu)"
```

### Other Geant4 examples

- **underground_physics** — shielding optimization and neutron moderation logic.
  Add a simple slab of material in `DetectorConstruction`; compare rates / energy
  deposition downstream.

  ```bash
  cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_GEANT4_UIVIS=ON \
    -DDMXENV_GPS_USE=ON \
    -DCMAKE_PREFIX_PATH="$(geant4-config --prefix);$ROOT_DIR"
  cmake --build build -j"$(sysctl -n hw.ncpu)"
  ```

- **lAr_calorimeter** — LAr veto light-collection sensitivity. Change scintillation
  yield and absorption length; measure detected photoelectrons vs distance/geometry.
- **xray_fluorescence** — pick a material, fire gammas/electrons at a surface, and
  verify the fluorescence X-ray lines appear in the output spectrum (background line
  ID and detector material-response sanity checks).
- **IAEAphsp** — realistic source generation reusing precomputed phase-space inputs;
  reproducible source-modeling patterns.
- **human_phantom** — geometry organization and run control.

## remage

**Build** (against the installed remage — set `REMAGE_PREFIX` to its install dir,
and `ROOT_DIR` if using ROOT):

```bash
rm -f *.root
rm -f *.hdf5
rm -rf build
cmake -S . -B build \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -Dremage_DIR="$REMAGE_PREFIX/lib/cmake/remage" \
  -DCMAKE_PREFIX_PATH="$REMAGE_PREFIX;$BXDECAY0_PREFIX;$GEANT4_BASE;/opt/homebrew"
cmake --build build -j"$(sysctl -n hw.ncpu)"
```

**Run**

```bash
# ex1
#   UI mode:    ./build/<sim>   then  /control/execute <mac>
#   batch mode: ./build/<sim> <mac>

# ex2 & ex3
#   UI mode:    ./build/<sim> -i <mac>
#   batch mode: ./build/<sim> <mac>
```

### examples/01-gdml

> Rewrote `main.cc` to have UI and rewrote the vis macros to work.

Goal: prove you can ingest a realistic detector-stand geometry via GDML and run
particles through it.

- **Geometry hierarchy:** `main.gdml` composes modules (cryostat, holder, wrap,
  source) into a world.
- **Materials + overlaps:** duplicate material-name warnings; tiny overlaps cause
  tracking artifacts.
- **Vertex confinement efficiency:** geometric acceptance of the defined source volume.

Run `run.mac` (batch) and confirm stability. Switch the generator in the macros
(GPS) between gammas/electrons/ions and observe interaction signatures. Add a thin
dead layer or change material and watch gross rate changes (systematics intuition).

### examples/02-hpge

> Created script `analyze_hpge_hdf5.ipynb`.
> The geometry + physics + generator parts in `run.mac` are fine.
> The vis macros do their own `/run/initialize` and then set up visualization +
> (for `vis-traj.mac`) define a GPS source and run `/run/beamOn 100`.

Goal: define an HPGe detector (geometry + sensitive detector + scoring) and learn
which quantities can output:

- Energy deposition in active Ge (spectrum shape)
- Single-site vs multi-site behavior (Compton vs photoelectric)
- How geometry changes peak efficiency

This is the core of LEGEND-style "what deposits near Q_ββ" thinking.

### examples/03-optics

LAr veto — optical photons and scintillation/absorption.

- Optical photon tracking + PMT/SiPM or optical surfaces / storing optical
  observables into ROOT
- How optical transport depends on surface definitions (polish, reflectivity).
- Why optical simulation is expensive and requires careful reduction/observables.

LEGEND uses LAr veto concepts; optical response matters when you interpret veto
performance, light yield, and veto coincidence rates — the conceptual bridge to
LEGEND LAr veto light collection and surface modeling.

### examples/04-cosmogenics

Cosmogenic production/activation and/or cosmogenic event generation.

- Activate isotopes, or simulate cosmogenic-induced decays in/near HPGe detectors.
- Which isotopes dominate in Ge for your exposure assumptions.
- How delayed backgrounds arise from activation products.

Cosmogenic isotopes drive background models.

### examples/05-MUSUN

Use an external muon generator input (MUSUN CSV) to drive the simulation for
underground muon backgrounds.

- Muons are sampled from a precomputed distribution (energy, angle, position).
- The remage generator reads and injects muons accordingly.
- Muon-induced backgrounds are geometry-dependent and rare but high-impact.
- External muon spectrum → event injection → secondaries → detector response.
- Secondary neutrons and gammas as a function of material around the detector.
- Modeling muon flux and angular distribution is essential for background budgets.

Covers cosmogenic + muon-induced backgrounds and veto strategies.

### examples/06-NeutronCapture

Validate neutron capture models and gamma cascades in materials.

- Simulating n-capture.
- Recording which isotopes captured.
- Recording gamma cascade properties.
- Capture gamma cascades are a major background mechanism.
- How to implement a custom output scheme for specific physics questions
  (isotope accounting).
- Neutron capture in materials (Cu, SS, Ar, etc.) creates gamma lines and Compton
  continua near ROI.

Drives material choice + neutron moderation strategy.

### examples/07-my-legend-study

_Placeholder for your own LEGEND study._

### remage — systematic workflow

**Step 1 — Geometry sanity + reproducibility**
- Always run a batch macro first (no UI) and confirm: the overlap check is clean
  enough for tracking, and the event rate is stable.
- Fix geometry before physics — otherwise you chase ghosts.

**Step 2 — Single-process intuition (HPGe)**
- Run monoenergetic gammas and electrons and build intuition:
  - Photopeak vs Compton continuum (gamma)
  - Bremsstrahlung + MCS + range (electron)
  - Sensitivity to dead layer / holder material

**Step 3 — Add realistic sources (decays, chains)**
- Use BxDecay0 / built-in decay machinery where appropriate.
- Compare "truth-level emission" vs "detected deposition".

**Step 4 — Add correlated handles (tracks, timing, veto)**
- Turn on track output schemes where available.
- For LAr optics: treat "light yield → veto" as a physics handle.

### LEGEND-200

**What backgrounds survive all cuts near Q_ββ?** In simulation lingo:
- Generate backgrounds in the correct place (materials and surfaces).
- Transport them through the real geometry.
- Record observables used in analysis: energy in detectors, multiplicity,
  distances, timing/veto flags.

**What is the signal efficiency?**
- Generate 0νββ decays in the active volume.
- Track energy depositions and topology proxies (multi-site vs single-site).
- Include detector effects later (resolution, thresholds).
