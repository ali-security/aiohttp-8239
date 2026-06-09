#!/usr/bin/env bash
# Rebuild the macOS wheels for aiohttp 2.3.9+sp1.
#
# Why this exists: 2.3.9's original macOS CI is dead. cp36 builds with a conda-forge
# interpreter; cp34 has NO prebuilt that runs on current macOS (python.org's 10.6 fat
# build and conda's 3.4.5 both crash: CoreFoundation/dyld), so cp34 is built from a
# CPython 3.4.10 compiled from source on the host.
#
# Requirements: an INTEL macOS host (x86_64) with Homebrew — e.g. a physical Intel Mac
# or the `macos-15-intel` GitHub runner (see process/macos-build.yml). Conda is auto-
# installed (Miniforge) if missing. Produces wheels into ../build_output/; then run
# post_build to rename (+sp1) into seal_artifacts/.
#
# Tiers: cp34 -> macosx_10_10 + 10_11 ; cp36 -> macosx_10_10.
set -euxo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VDIR="$(dirname "$HERE")"
OUT="${OUT:-$VDIR/build_output}"; mkdir -p "$OUT"
TAG=v2.3.9
CYTHON=0.27.1            # matches the public 2.3.9 wheels' Generator/Cython

# Patched source: use $SOURCE if already patched, else clone upstream + apply our patch
# (the CVE patch carries the vendored Brotli C *and* its c/include/brotli/*.h headers).
if [ -n "${SOURCE:-}" ]; then
  SRC="$SOURCE"
else
  SRC="$(mktemp -d)/aiohttp"
  git clone --depth 1 --branch "$TAG" https://github.com/aio-libs/aiohttp.git "$SRC"
  git -C "$SRC" apply "$VDIR/patches/CVE-2025-69223.patch"
fi

if ! command -v conda >/dev/null 2>&1; then
  curl -fsSL -o /tmp/mf.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-x86_64.sh
  bash /tmp/mf.sh -b -p "$HOME/miniforge3"; export PATH="$HOME/miniforge3/bin:$PATH"
fi
source "$(conda info --base)/etc/profile.d/conda.sh"
RETAG_PY="$(conda info --base)/bin/python"     # modern python for retag + RECORD-perm fix
"$RETAG_PY" -m pip install -q -U wheel

# normalize dist-info/RECORD perm to 0o644 (build env emits 0o664; public is 0o644)
norm_record() { "$RETAG_PY" - "$1" <<'PY'
import zipfile, os, sys
w = sys.argv[1]; tmp = w + ".t"
with zipfile.ZipFile(w) as zi, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
    for it in zi.infolist():
        data = zi.read(it.filename)
        if it.filename.endswith("/RECORD"):
            it.external_attr = (it.external_attr & ~(0o777 << 16)) | (0o644 << 16)
        zo.writestr(it, data)
os.replace(tmp, w)
PY
}

# ---------- cp36 (conda) -> macosx_10_10 ----------
conda create -y -n py36 -c conda-forge python=3.6.15
conda activate py36
export MACOSX_DEPLOYMENT_TARGET=10.10 ARCHFLAGS="-arch x86_64"
export CFLAGS="-Wno-error=implicit-function-declaration -Wno-error=implicit-int -mmacosx-version-min=10.10"
export LDFLAGS="-mmacosx-version-min=10.10"
python -m pip install -q "cython==$CYTHON" 'wheel==0.30.0' 'setuptools<44'
rm -rf /tmp/wh36; ( cd "$SRC" && rm -rf build && python setup.py bdist_wheel -d /tmp/wh36 )
conda deactivate
"$RETAG_PY" -m wheel tags --platform-tag macosx_10_10_x86_64 --remove /tmp/wh36/*.whl
norm_record /tmp/wh36/*.whl; mv /tmp/wh36/*.whl "$OUT/"

# ---------- cp34 (CPython 3.4.10 from source) -> macosx_10_10 + 10_11 ----------
brew list zlib >/dev/null 2>&1 || brew install zlib
SDK="$(xcrun --show-sdk-path)"; ZP="$(brew --prefix zlib)"
DEMOTE="-Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types"
rm -rf /tmp/Python-3.4.10*; ( cd /tmp && curl -sSLO https://www.python.org/ftp/python/3.4.10/Python-3.4.10.tgz && tar xzf Python-3.4.10.tgz )
cd /tmp/Python-3.4.10
grep -q 'sys/random.h' Python/random.c || perl -0pi -e 's{#include "Python.h"}{#include "Python.h"\n#include <sys/random.h>}' Python/random.c
CFLAGS="-isysroot $SDK -arch x86_64 $DEMOTE -I$ZP/include" \
CPPFLAGS="-isysroot $SDK -I$ZP/include -I$SDK/usr/include" \
LDFLAGS="-isysroot $SDK -arch x86_64 -L$ZP/lib" \
CPATH="$ZP/include:$SDK/usr/include" LIBRARY_PATH="$ZP/lib:$SDK/usr/lib" ARCHFLAGS="-arch x86_64" \
  ./configure --prefix=/tmp/py34 --enable-shared --without-ensurepip MACOSX_DEPLOYMENT_TARGET=10.10
make -j"$(sysctl -n hw.ncpu)"; make install
PY34=/tmp/py34/bin/python3.4; export DYLD_LIBRARY_PATH=/tmp/py34/lib
"$PY34" -c "import zlib, zipfile; zipfile._check_compression(zipfile.ZIP_DEFLATED); print('zlib+deflate OK')"
# era build deps as cp34 wheels (no pip/TLS): Cython 0.27.1 / setuptools 43 / wheel 0.30
rm -rf /tmp/d34; mkdir -p /tmp/d34; cd /tmp/d34
curl -sSLO https://files.pythonhosted.org/packages/6b/6a/fa8d20fb8b661854a7140e290c52693ab3e8afdc9a8a7bf1194d9a227918/Cython-0.27.1-cp34-cp34m-macosx_10_6_intel.macosx_10_9_intel.macosx_10_9_x86_64.macosx_10_10_intel.macosx_10_10_x86_64.whl
curl -sSLO https://files.pythonhosted.org/packages/91/af/18d58ed8a8e7e6b91d71b0367034faf8ea41e1004018811388ed07a7f2d6/setuptools-43.0.0-py2.py3-none-any.whl
curl -sSLO https://files.pythonhosted.org/packages/0c/80/16a85b47702a1f47a63c104c91abdd0a6704ee8ae3b4ce4afc49bc39f9d9/wheel-0.30.0-py2.py3-none-any.whl
SP="$("$PY34" -c 'import site; print(site.getsitepackages()[0])')"
for w in *.whl; do "$PY34" -m zipfile -e "$w" "$SP"; done
rm -rf /tmp/wh34; cd "$SRC"; rm -rf build
CFLAGS="$DEMOTE" ARCHFLAGS="-arch x86_64" MACOSX_DEPLOYMENT_TARGET=10.10 "$PY34" setup.py bdist_wheel -d /tmp/wh34
# setup.py silently falls back to a pure-Python wheel if an extension fails to build — assert the .so is in
"$PY34" -m zipfile -l /tmp/wh34/*.whl | grep -q '_vendored/_brotli.*\.so'
norm_record /tmp/wh34/*.whl
cp /tmp/wh34/*.whl "$OUT/"                       # bdist auto-tags macosx_10_10
mkdir -p /tmp/r11; cp /tmp/wh34/*.whl /tmp/r11/  # retag a copy to 10_11 (metadata only)
"$RETAG_PY" -m wheel tags --platform-tag macosx_10_11_x86_64 --remove /tmp/r11/*.whl
norm_record /tmp/r11/*macosx_10_11_x86_64.whl; mv /tmp/r11/*macosx_10_11_x86_64.whl "$OUT/"

echo "=== built into $OUT ==="
ls -la "$OUT"/*macosx*.whl
