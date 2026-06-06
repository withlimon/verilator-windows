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

GCC_POSIX=$(ls /usr/bin/x86_64-w64-mingw32-gcc-posix 2>/dev/null || ls /usr/bin/x86_64-w64-mingw32-gcc-*posix* 2>/dev/null | head -1)
GPP_POSIX=$(ls /usr/bin/x86_64-w64-mingw32-g++-posix 2>/dev/null || ls /usr/bin/x86_64-w64-mingw32-g++-*posix* 2>/dev/null | head -1)

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
cp -r include/. "$PKG/include/"

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

FILE="$PKG/bin/verilator${EXE}"
test -e "$FILE" || { echo "FAIL: file missing"; exit 1; }
file "$FILE" | grep -q "PE32+" || { echo "FAIL: not PE32+"; exit 1; }
"$HOST-objdump" -p "$FILE" | grep "DLL Name"

echo "VERSION=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "TARBALL=$TARBALL" >> "${GITHUB_OUTPUT:-/dev/null}"

echo ""
echo "Package : $TARBALL"
echo "Size    : $(ls -lh "$TARBALL" | awk '{print $5}')"
echo "SHA1    : $(sha1sum "$TARBALL" | cut -d' ' -f1)"
