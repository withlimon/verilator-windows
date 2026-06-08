#!/bin/bash
#################################################################
# Unfused Verilator Toolchain Cross-Builder Script              #
# Combined & Refactored to build entirely using Git Sources    #
#################################################################
set -e
set -o pipefail

# -- Version Tracker & Configuration
VERSION=5.048
ARCH=$1
TARGET_ARCHS="linux_x86_64 linux_i686 linux_armv7l linux_aarch64 windows_x86 windows_amd64 darwin"
NAME=toolchain-verilator

# -- Flag Controls
INSTALL_DEPS=1
COMPILE_VERILATOR=1
CREATE_PACKAGE=1

# -- Environment Work Directories
WORK_DIR=$PWD
BUILDS_DIR=$WORK_DIR/_builds
PACKAGES_DIR=$WORK_DIR/_packages
UPSTREAM_DIR=$WORK_DIR/_upstream

# -- Scaffold Base File System
mkdir -p "$BUILDS_DIR" "$PACKAGES_DIR" "$UPSTREAM_DIR"

# -- Utility Print Functions
function print_status {
  echo ""
  echo ">>> $1"
  echo ""
}

# -- Check Target Architecture Input
if [[ $# > 1 ]]; then
  echo "Error: too many arguments"
  exit 1
fi

if [[ $# < 1 ]]; then
  echo "Usage: bash build.sh TARGET"
  echo "Targets: $TARGET_ARCHS"
  exit 1
fi

if [[ $ARCH =~ [[:space:]] || ! $TARGET_ARCHS =~ (^|[[:space:]])$ARCH([[:space:]]|$) ]]; then
  echo ">>> WRONG ARCHITECTURE \"$ARCH\""
  exit 1
fi

print_status "TARGET ARCHITECTURE COMPILING: $ARCH"

BUILD_DIR=$BUILDS_DIR/build_$ARCH
PACKAGE_DIR=$PACKAGES_DIR/build_$ARCH

# =================================================================
# 1. DEPENDENCY SETUP STAGE
# =================================================================
if [ "$INSTALL_DEPS" == "1" ]; then
  print_status "Installing cross-platform toolchain build dependencies..."
  
  sudo apt-get update -qq
  
  if [ "$ARCH" == "linux_x86_64" ]; then
    sudo apt-get install -y build-essential bison flex gperf autoconf git perl python3 make rsync
  fi

  if [ "$ARCH" == "linux_i686" ]; then
    sudo apt-get install -y build-essential bison flex gperf autoconf git perl python3 make rsync \
                            gcc-multilib g++-multilib
  fi

  if [ "$ARCH" == "linux_armv7l" ]; then
    sudo apt-get install -y build-essential bison flex gperf autoconf git perl python3 make rsync \
                            gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
                            binfmt-support qemu-user-static
  fi

  if [ "$ARCH" == "linux_aarch64" ]; then
    sudo apt-get install -y build-essential bison flex gperf autoconf git perl python3 make rsync \
                            gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
                            binfmt-support qemu-user-static
  fi

  if [ "${ARCH:0:7}" == "windows" ]; then
    sudo apt-get install -y build-essential bison flex gperf autoconf git perl python3 make rsync \
                            mingw-w64 mingw-w64-tools wine
  fi

  if [ "$ARCH" == "darwin" ]; then
    DEPS="bison flex autoconf git"
    brew update
    brew install --force $DEPS
    brew unlink $DEPS && brew link --force $DEPS
  fi
  
  sudo apt-get autoremove -y
fi

# =================================================================
# 2. CROSS-COMPILER MATRIX FLAGS DEFINITIONS
# =================================================================
EXE=""
HOST="x86_64-linux-gnu"
CONFIG_HOST=""
MAKE_CFLAGS="-O2"
MAKE_CXXFLAGS="-O2"
MAKE_LDFLAGS="-static"

if [ "$ARCH" == "linux_i686" ]; then
  CONFIG_HOST="-m32"
  MAKE_LDFLAGS="-m32 -static"
fi

if [ "$ARCH" == "linux_armv7l" ]; then
  HOST="arm-linux-gnueabihf"
fi

if [ "$ARCH" == "linux_aarch64" ]; then
  HOST="aarch64-linux-gnu"
fi

if [ "$ARCH" == "windows_x86" ]; then
  EXE=".exe"
  HOST="i686-w64-mingw32"
fi

if [ "$ARCH" == "windows_amd64" ]; then
  EXE=".exe"
  HOST="x86_64-w64-mingw32"
  MAKE_LDFLAGS="-static -static-libgcc -static-libstdc++"
fi

if [ "$ARCH" == "darwin" ]; then
  J=$(($(sysctl -n hw.ncpu) - 1))
else
  J=$(($(nproc) - 1))
  BUILD="x86_64-unknown-linux-gnu"
fi
[ "$J" -lt 1 ] && J=1

# Setup compiler overrides for windows targeting configurations
if [ "${ARCH:0:7}" == "windows" ]; then
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
elif [ "$ARCH" != "darwin" ]; then
  export CC="$HOST-gcc $CONFIG_HOST"
  export CXX="$HOST-g++ $CONFIG_HOST"
fi

# Create target environment directories
mkdir -p "$BUILD_DIR"
mkdir -p "$PACKAGE_DIR/$NAME/bin"

# =================================================================
# 3. SOURCE RETRIEVAL & VERILATOR COMPILATION
# =================================================================
if [ "$COMPILE_VERILATOR" == "1" ]; then
  print_status "Compiling Verilator System via GitHub Source Tracking..."

  cd "$UPSTREAM_DIR"
  if [ ! -d "verilator" ]; then
    git clone --branch stable https://github.com/verilator/verilator.git
    cd verilator
  else
    cd verilator
    git pull
  fi

  VERSION=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//')
  print_status "Building Verilator Target Release v$VERSION"

  # Sync source tree into structural builds directory 
  rsync -a . "$BUILD_DIR/verilator" --exclude .git
  cd "$BUILD_DIR/verilator"

  if [ "${ARCH:0:7}" == "windows" ]; then
    FLEXLEXER=$(find /usr/include /usr/local/include -name "FlexLexer.h" 2>/dev/null | head -1)
    [ -n "$FLEXLEXER" ] && cp "$FLEXLEXER" src/.
  fi

  # Apply configuration bypass patches via automated pipeline stream
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

  # Run generation configuration with absolute path translation stripped out
  if [ "$ARCH" == "darwin" ]; then
    ./configure --prefix="$PACKAGE_DIR/$NAME" --datadir='${prefix}/share'
  else
    ./configure --build="$BUILD" --host="$HOST" --prefix="$PACKAGE_DIR/$NAME" --datadir='${prefix}/share'
  fi

  cd src
  make opt -j"$J" CFLAGS="$MAKE_CFLAGS" CXXFLAGS="$MAKE_CXXFLAGS" LDFLAGS="$MAKE_LDFLAGS"

  # Output Stripping and Binary Installation Execution
  if [ "${ARCH:0:7}" == "windows" ]; then
    file bin/verilator_bin.exe | grep -q "PE32+" || { echo "ERROR: File is not a valid Windows build."; exit 1; }
    "$HOST-strip" bin/verilator_bin.exe
    cp bin/verilator_bin.exe "$PACKAGE_DIR/$NAME/bin/verilator$EXE"
  else
    cp bin/verilator_bin "$PACKAGE_DIR/$NAME/bin/verilator"
  fi

  # Stage include libraries
  cp -r ../include/. "$PACKAGE_DIR/$NAME/include/"

  # Stage and structuralizing Core Framework Waivers & Internal Definition Mappings
  mkdir -p "$PACKAGE_DIR/$NAME/share/verilator/include"
  cp verilated_std_waiver.vlt "$PACKAGE_DIR/$NAME/share/verilator/include/"
  cp verilated_std.sv "$PACKAGE_DIR/$NAME/share/verilator/include/"
fi

# =================================================================
# 4. EXPORT PACKAGING STAGE
# =================================================================
if [ "$CREATE_PACKAGE" == "1" ]; then
  print_status "Structuring output distribution packages..."

  # Generate clean structured templates dynamically
  cat > "$PACKAGE_DIR/$NAME/package.json" << EOF
{
  "name": "$NAME",
  "description": "Verilator core automated toolchain asset package",
  "url": "https://github.com/verilator/verilator",
  "version": "$VERSION",
  "system": [ "$ARCH" ]
}
EOF

  # If targeting execution on Windows hosts, wrap with dynamic runtime auto-discovery
  if [ "${ARCH:0:7}" == "windows" ]; then
    cat > "$PACKAGE_DIR/$NAME/bin/verilator.bat" << 'EOF'
@echo off
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "VERILATOR_ROOT=%%~fI"
"%SCRIPT_DIR%verilator.exe" %*
EOF
  fi

  # Run standard tar archive distribution output extraction
  cd "$PACKAGE_DIR/$NAME"
  tar -czvf "../$NAME-$ARCH-$VERSION.tar.gz" *

  TARBALL="$PACKAGE_DIR/../$NAME-$ARCH-$VERSION.tar.gz"
  print_status "COMPILATION SUCCESSFUL!"
  echo "Package Asset Created : $NAME-$ARCH-$VERSION.tar.gz"
fi
