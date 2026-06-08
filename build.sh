#copyright Limon DAS
# based on https://github.com/FPGAwars/toolchain-verilator cross compile script
#!/bin/bash
set -e
set -o pipefail

ARCH=windows_amd64
NAME=verilator-windows

WORK_DIR=$PWD
UPSTREAM_DIR=$WORK_DIR/_upstream
BUILD_DIR=$WORK_DIR/_builds/build_$ARCH
PACKAGE_DIR=$WORK_DIR/_packages/build_$ARCH
PKG=$PACKAGE_DIR/$NAME

EXE=".exe"
HOST="x86_64-w64-mingw32"
BUILD="x86_64-unknown-linux-gnu"
MAKE_CFLAGS="-O2"
MAKE_CXXFLAGS="-O2"
MAKE_LDFLAGS="-static -static-libgcc -static-libstdc++"
J=$(($(nproc) - 1))
[ "$J" -lt 1 ] && J=1

mkdir -p "$UPSTREAM_DIR" "$BUILD_DIR" "$PKG/bin"

sudo apt-get update -qq
sudo apt-get install -y \
    build-essential bison flex gperf autoconf \
    git help2man perl python3 make rsync \
    libfl-dev zlib1g-dev \
    mingw-w64 mingw-w64-tools

GCC_POSIX=$(ls /usr/bin/x86_64-w64-mingw32-gcc-posix 2>/dev/null || \
            ls /usr/bin/x86_64-w64-mingw32-gcc-*posix* 2>/dev/null | head -1)
GPP_POSIX=$(ls /usr/bin/x86_64-w64-mingw32-g++-posix 2>/dev/null || \
            ls /usr/bin/x86_64-w64-mingw32-g++-*posix* 2>/dev/null | head -1)

if [ -n "$GCC_POSIX" ]; then
    sudo update-alternatives --set x86_64-w64-mingw32-gcc "$GCC_POSIX" 2>/dev/null || true
fi
if [ -n "$GPP_POSIX" ]; then
    sudo update-alternatives --set x86_64-w64-mingw32-g++ "$GPP_POSIX" 2>/dev/null || true
fi

export CC="${GCC_POSIX:-x86_64-w64-mingw32-gcc}"
export CXX="${GPP_POSIX:-x86_64-w64-mingw32-g++}"
export AR="$HOST-ar"
export RANLIB="$HOST-ranlib"

echo "CC  = $CC  -> $($CC --version | head -1)"
echo "CXX = $CXX -> $($CXX --version | head -1)"

cd "$UPSTREAM_DIR"
git clone --branch stable https://github.com/verilator/verilator.git
cd verilator

VERSION=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//')
echo "Building Verilator v$VERSION for $ARCH"

FLEXLEXER=$(find /usr/include /usr/local/include -name "FlexLexer.h" 2>/dev/null | head -1)
[ -n "$FLEXLEXER" ] && cp "$FLEXLEXER" src/.

python3 - <<'EOF'
import sys
with open('configure.ac', 'r') as f:
    c = f.read()
old = '     [_my_result=yes],\n     [_my_result=no],\n     [_my_result=no])\n   ])'
new = '     [_my_result=yes],\n     [_my_result=no],\n     [_my_result=yes])\n   ])'
if old not in c:
    print("ERROR: patch target not found in configure.ac"); sys.exit(1)
with open('configure.ac', 'w') as f:
    f.write(c.replace(old, new))
EOF

autoconf

./configure --build="$BUILD" --host="$HOST" --prefix="$PKG"

make -j"$J" -C src opt \
    CFLAGS="$MAKE_CFLAGS" \
    CXXFLAGS="$MAKE_CXXFLAGS" \
    LDFLAGS="$MAKE_LDFLAGS"

file bin/verilator_bin.exe | grep -q "PE32+" || { echo "ERROR: not PE32+"; exit 1; }

"$HOST-strip" bin/verilator_bin.exe

cp bin/verilator_bin.exe "$PKG/bin/verilator${EXE}"

# ── FIX 1: Copy include files to ALL locations Verilator searches ──
cp -r include/. "$PKG/include/"
mkdir -p "$PKG/share/verilator/include"
cp -r include/. "$PKG/share/verilator/include/"

# ── FIX 2: Patch verilated.mk — replace Linux cross-compiler names
#           with portable names so w64devkit g++ works on Windows ──
for MK_FILE in "$PKG/include/verilated.mk" "$PKG/share/verilator/include/verilated.mk"; do
    if [ -f "$MK_FILE" ]; then
        sed -i 's|x86_64-w64-mingw32-g++-posix|g++|g'   "$MK_FILE"
        sed -i 's|x86_64-w64-mingw32-gcc-posix|gcc|g'   "$MK_FILE"
        sed -i 's|x86_64-w64-mingw32-g++|g++|g'         "$MK_FILE"
        sed -i 's|x86_64-w64-mingw32-gcc|gcc|g'         "$MK_FILE"
        sed -i 's|x86_64-w64-mingw32-ar|ar|g'           "$MK_FILE"
        echo "Patched: $MK_FILE"
    fi
done

# ── FIX 3: Create a Windows batch wrapper (verilator.bat)
#           so users don't need to set VERILATOR_ROOT manually ──
cat > "$PKG/bin/verilator.bat" << 'BATEOF'
@echo off
:: Auto-detect VERILATOR_ROOT from this script's location
SET SCRIPT_DIR=%~dp0
SET VERILATOR_ROOT=%SCRIPT_DIR%..
SET VERILATOR_ROOT=%VERILATOR_ROOT:\=/%

:: Ensure g++ (w64devkit) is available
WHERE g++ >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo ERROR: g++ not found. Please open w64devkit terminal or add g++ to PATH.
    exit /b 1
)

:: Run verilator with correct root
SET PATH=%SCRIPT_DIR%;%PATH%
verilator.exe %*
BATEOF

# ── FIX 4: Create a helper run script for w64devkit shell ──
cat > "$PKG/bin/verilator.sh" << 'SHEOF'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export VERILATOR_ROOT="$(dirname "$SCRIPT_DIR")"
exec "$SCRIPT_DIR/verilator.exe" "$@"
SHEOF
chmod +x "$PKG/bin/verilator.sh"

# ── FIX 5: README for Windows users ──
cat > "$PKG/README_WINDOWS.txt" << READMEEOF
=== Verilator $VERSION for Windows (w64devkit) ===

REQUIREMENTS:
  - w64devkit: https://github.com/skeeto/w64devkit/releases

SETUP (run once):
  1. Extract this package to a folder, e.g. C:\verilator
  2. Add to PATH (User environment variable):
       C:\verilator\bin
  3. Set VERILATOR_ROOT (User environment variable):
       C:\verilator

USAGE (always from w64devkit terminal):
  verilator --cc --top-module top test.sv
  make -C obj_dir -f Vtop.mk

  OR for direct binary build:
  verilator --binary --top-module top test.sv

DO NOT use cmd.exe or PowerShell — use w64devkit shell only.
READMEEOF

cat > "$PKG/package.json" << EOF
{
  "name": "verilator-windows",
  "description": "Verilator for windows",
  "url": "https://github.com/withlimon/verilator-windows",
  "version": "$VERSION",
  "system": [ "windows", "windows_amd64" ]
}
EOF

cd "$PKG"
tar -czvf "$PACKAGE_DIR/${NAME}-${ARCH}-${VERSION}.tar.gz" *

TARBALL="$PACKAGE_DIR/${NAME}-${ARCH}-${VERSION}.tar.gz"
# ── FIX 6: Copy all verilator helper scripts to bin/ ──
for SCRIPT in verilator_includer verilator_gantt verilator_profcfunc; do
    SRC="$UPSTREAM_DIR/verilator/bin/$SCRIPT"
    if [ -f "$SRC" ]; then
        cp "$SRC" "$PKG/bin/$SCRIPT"
        echo "Copied helper: $SCRIPT"
    fi
done

# Also copy any bin/ perl/python scripts
cp "$UPSTREAM_DIR/verilator/bin/verilator" "$PKG/bin/verilator" 2>/dev/null || true
cp "$UPSTREAM_DIR/verilator/bin/"verilator_* "$PKG/bin/" 2>/dev/null || true
# ── Verification ──
FILE="$PKG/bin/verilator${EXE}"
test -e "$FILE"                          || { echo "FAIL: binary missing";    exit 1; }
file "$FILE" | grep -q "PE32+"           || { echo "FAIL: not PE32+";         exit 1; }
test -f "$PKG/include/verilated.mk"      || { echo "FAIL: verilated.mk missing"; exit 1; }
test -f "$PKG/include/verilated_std.sv"  || { echo "FAIL: verilated_std.sv missing"; exit 1; }
grep -q "x86_64-w64-mingw32" "$PKG/include/verilated.mk" \
                                         && { echo "FAIL: mk still has cross-compiler"; exit 1; }
"$HOST-objdump" -p "$FILE" | grep "DLL Name"

echo "VERSION=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "TARBALL=$TARBALL"  >> "${GITHUB_OUTPUT:-/dev/null}"

echo ""
echo "================================================"
echo " Package : $TARBALL"
echo " Size    : $(ls -lh "$TARBALL" | awk '{print $5}')"
echo " SHA1    : $(sha1sum "$TARBALL" | cut -d' ' -f1)"
echo "================================================"
echo " Fixes applied:"
echo "  [1] include/ mirrored to share/verilator/include/"
echo "  [2] verilated.mk cross-compiler names patched to g++/gcc"
echo "  [3] verilator.bat auto-detects VERILATOR_ROOT"
echo "  [4] verilator.sh wrapper for w64devkit shell"
echo "  [5] README_WINDOWS.txt included"
echo "================================================"
