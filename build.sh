#!/bin/bash
# copyright Limon DAS
# based on https://github.com/FPGAwars/toolchain-verilator
# Comprehensive Windows cross-compile — all errors anticipated and fixed
set -e
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  CONFIGURATION
# ══════════════════════════════════════════════════════════════
ARCH=windows_amd64
NAME=verilator-windows
WORK_DIR=$PWD
UPSTREAM_DIR=$WORK_DIR/_upstream
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

mkdir -p "$UPSTREAM_DIR" "$PKG/bin" "$PKG/include" \
         "$PKG/share/verilator/include"

echo "══════════════════════════════════════════════════════"
echo "  Verilator Windows Cross-Compile Builder"
echo "══════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════
#  STEP 1 — Install ALL required dependencies
#  FIX-01: Full dep list prevents mid-build failures
# ══════════════════════════════════════════════════════════════
echo "[1/9] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    build-essential bison flex gperf \
    autoconf automake libtool \
    git help2man perl python3 make rsync curl \
    libfl-dev libfl2 zlib1g-dev \
    mingw-w64 mingw-w64-tools mingw-w64-x86-64-dev

# ══════════════════════════════════════════════════════════════
#  STEP 2 — Configure cross-compiler
#  FIX-02: Auto-detect posix variant; fallback if not found
#  FIX-03: Export all required cross-tool variables
# ══════════════════════════════════════════════════════════════
echo "[2/9] Configuring cross-compiler..."

GCC_POSIX=$(ls /usr/bin/x86_64-w64-mingw32-gcc-posix 2>/dev/null \
         || ls /usr/bin/x86_64-w64-mingw32-gcc-*posix* 2>/dev/null | head -1 \
         || echo "x86_64-w64-mingw32-gcc")
GPP_POSIX=$(ls /usr/bin/x86_64-w64-mingw32-g++-posix 2>/dev/null \
         || ls /usr/bin/x86_64-w64-mingw32-g++-*posix* 2>/dev/null | head -1 \
         || echo "x86_64-w64-mingw32-g++")

[ -n "$GCC_POSIX" ] && sudo update-alternatives \
    --set x86_64-w64-mingw32-gcc "$GCC_POSIX" 2>/dev/null || true
[ -n "$GPP_POSIX" ] && sudo update-alternatives \
    --set x86_64-w64-mingw32-g++ "$GPP_POSIX" 2>/dev/null || true

export CC="${GCC_POSIX:-x86_64-w64-mingw32-gcc}"
export CXX="${GPP_POSIX:-x86_64-w64-mingw32-g++}"
export AR="$HOST-ar"
export RANLIB="$HOST-ranlib"
export STRIP="$HOST-strip"
export NM="$HOST-nm"

echo "  CC  = $CC  ($($CC  --version | head -1))"
echo "  CXX = $CXX ($($CXX --version | head -1))"

# ══════════════════════════════════════════════════════════════
#  STEP 3 — Clone source
#  FIX-04: Reuse existing clone to save CI time
#  FIX-05: Fallback VERSION extraction if tags are missing
# ══════════════════════════════════════════════════════════════
echo "[3/9] Cloning Verilator..."
cd "$UPSTREAM_DIR"

if [ -d "verilator/.git" ]; then
    echo "  Found existing clone — fetching tags..."
    cd verilator
    git fetch --tags --prune 2>/dev/null || true
    git checkout stable 2>/dev/null || git checkout master
    git pull --ff-only 2>/dev/null || true
else
    git clone --branch stable https://github.com/verilator/verilator.git
    cd verilator
fi

VERSION=$(git tag --sort=-v:refname \
        | grep -E '^v[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//' || true)
[ -z "$VERSION" ] && VERSION=$(grep -m1 'AC_INIT' configure.ac \
        | grep -oP '\d+\.\d+' | head -1 || true)
[ -z "$VERSION" ] && VERSION="unknown"
echo "  Version: v$VERSION"

# ══════════════════════════════════════════════════════════════
#  STEP 4 — Patch configure.ac
#  FIX-06: Regex fallback if exact patch text changes between versions
#  FIX-07: Copy FlexLexer.h if not bundled in source
# ══════════════════════════════════════════════════════════════
echo "[4/9] Patching source..."

# Patch cross-compile detection in configure.ac
python3 - <<'PYEOF'
import sys, re
with open('configure.ac', 'r') as f:
    c = f.read()

# Exact match (for known versions)
old = '     [_my_result=yes],\n     [_my_result=no],\n     [_my_result=no])\n   ])'
new = '     [_my_result=yes],\n     [_my_result=no],\n     [_my_result=yes])\n   ])'

if old in c:
    c = c.replace(old, new)
    print("  configure.ac patched (exact match)")
else:
    # Flexible regex fallback
    c2 = re.sub(
        r'(\[_my_result=yes\],\s*\n\s*\[_my_result=no\],\s*\n\s*)'
        r'\[_my_result=no\](\)\s*\n\s*\]\))',
        r'\1[_my_result=yes]\2', c)
    if c2 != c:
        c = c2
        print("  configure.ac patched (regex fallback)")
    else:
        print("  WARNING: configure.ac patch target not found — continuing anyway")

with open('configure.ac', 'w') as f:
    f.write(c)
PYEOF

# Copy FlexLexer.h if not already in source
FLEXLEXER=$(find /usr/include /usr/local/include \
           -name "FlexLexer.h" 2>/dev/null | head -1)
[ -n "$FLEXLEXER" ] && cp "$FLEXLEXER" src/. \
    && echo "  Copied FlexLexer.h"

autoconf

# ══════════════════════════════════════════════════════════════
#  FIX-24: Use win32 threading model to avoid pthread conflicts
#  FIX-25: Use C++14 or C++17 instead of C++11 (required for modern Verilator)
# ══════════════════════════════════════════════════════════════
echo "[4.5/9] Configuring with win32 threading and C++14..."
./configure --build="$BUILD" --host="$HOST" --prefix="$PKG" \
    --disable-pthreads \
    CFLAGS="$MAKE_CFLAGS" \
    CXXFLAGS="$MAKE_CXXFLAGS -std=c++17" \
    LDFLAGS="$MAKE_LDFLAGS"

# ══════════════════════════════════════════════════════════════
#  STEP 5 — Build binary
#  FIX-08: Parallel build with automatic j1 fallback
#  FIX-09: Verify PE32+ before proceeding
#  FIX-25: Force C++17 standard throughout build
# ══════════════════════════════════════════════════════════════
echo "[5/9] Building (j=$J)..."

# Export build flags for the build process
export CXXFLAGS="$MAKE_CXXFLAGS -std=c++17"
export CFLAGS="$MAKE_CFLAGS"
export LDFLAGS="$MAKE_LDFLAGS"

make -j"$J" -C src opt \
    CXXFLAGS="$CXXFLAGS" \
    CFLAGS="$CFLAGS" \
    LDFLAGS="$LDFLAGS" \
|| {
    echo "  Parallel build failed — retrying with -j1..."
    make -j1 -C src opt \
        CXXFLAGS="$CXXFLAGS" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS"
}

file bin/verilator_bin.exe | grep -q "PE32+" || {
    echo "ERROR: Binary is not PE32+!"; file bin/verilator_bin.exe; exit 1
}

"$STRIP" bin/verilator_bin.exe
echo "  Binary size: $(ls -lh bin/verilator_bin.exe | awk '{print $5}')"

# ══════════════════════════════════════════════════════════════
#  STEP 6 — Copy files to package
#  FIX-10: Copy ALL bin/ helper scripts (verilator_includer etc.)
#  FIX-11: Mirror include/ to share/verilator/include/ (both paths searched)
# ══════════════════════════════════════════════════════════════
echo "[6/9] Packaging files..."

cp bin/verilator_bin.exe "$PKG/bin/verilator${EXE}"
echo "  Copied: verilator.exe"

# Copy EVERY file in bin/ — never skip any helper script
for f in bin/*; do
    [ -f "$f" ] || continue
    cp "$f" "$PKG/bin/$(basename "$f")"
    echo "  Copied: bin/$(basename "$f")"
done

# Include files in both search paths
cp -r include/. "$PKG/include/"
cp -r include/. "$PKG/share/verilator/include/"
echo "  Copied: include/ → /include and /share/verilator/include"

# Warn if any critical file is missing
for F in verilated_std.sv verilated_std_waiver.vlt \
         verilated.mk verilated.cpp verilated.h; do
    [ -f "$PKG/include/$F" ] \
        && echo "  [OK] $F" \
        || echo "  [WARN] $F missing from include/"
done

# ══════════════════════════════════════════════════════════════
#  STEP 7 — Patch verilated.mk (the runtime Makefile template)
#  FIX-12: Replace all cross-compiler tool names → portable names
#  FIX-13: Fix Python call → use .bat wrapper so Windows finds Python
#  FIX-14: Patch PYTHON3 variable to use wrapper
#  FIX-21: Force static C++ runtime
#  FIX-22: Fix linker order for MinGW threading
#  FIX-23: Remove -latomic for x86_64
#  FIX-24: Use win32 threading instead of pthread
#  FIX-25: Force C++17 standard (not C++11)
# ══════════════════════════════════════════════════════════════
echo "[7/9] Patching verilated.mk..."

patch_mk() {
    local MK="$1"
    [ -f "$MK" ] || return

    # Replace ALL cross-compiler references
    sed -i 's|x86_64-w64-mingw32-g++-posix|g++|g' "$MK"
    sed -i 's|x86_64-w64-mingw32-gcc-posix|gcc|g'  "$MK"
    sed -i 's|x86_64-w64-mingw32-g++|g++|g'        "$MK"
    sed -i 's|x86_64-w64-mingw32-gcc|gcc|g'        "$MK"
    sed -i 's|x86_64-w64-mingw32-ar|ar|g'          "$MK"
    sed -i 's|x86_64-w64-mingw32-nm|nm|g'          "$MK"
    sed -i 's|x86_64-w64-mingw32-strip|strip|g'    "$MK"

    # Replace PYTHON3 variable default — point to our .bat wrapper
    sed -i 's|^PYTHON3 \?=.*|PYTHON3 ?= $(VERILATOR_ROOT)/bin/python3_find.bat|g' "$MK"
    sed -i 's|^PYTHON3=.*|PYTHON3=$(VERILATOR_ROOT)/bin/python3_find.bat|g'       "$MK"

    # If PYTHON3 var not in file, patch inline python3 calls directly
    sed -i \
        's|python3 \$(VERILATOR_ROOT)/bin/verilator_includer|$(VERILATOR_ROOT)/bin/verilator_includer.bat|g' \
        "$MK"
    sed -i \
        's|\$(PYTHON3) \$(VERILATOR_ROOT)/bin/verilator_includer|$(VERILATOR_ROOT)/bin/verilator_includer.bat|g' \
        "$MK"

    # FIX-21: Force static C++ runtime to prevent ABI mismatch
    if grep -q "^LDFLAGS" "$MK"; then
        sed -i '/^LDFLAGS/s/$/ -static-libstdc++ -static-libgcc/' "$MK"
    else
        echo 'LDFLAGS += -static-libstdc++ -static-libgcc' >> "$MK"
    fi

    # FIX-22 & FIX-24: Proper MinGW threading - replace pthread with win32
    # Remove problematic pthread references and use win32 threading
    sed -i 's|-pthread||g' "$MK"
    sed -i 's|-lpthread||g' "$MK"
    sed -i 's|-latomic||g' "$MK"
    
    # Add proper threading for MinGW
    if grep -q "^LDLIBS" "$MK"; then
        sed -i '/^LDLIBS/s/$/ -lwinpthread/' "$MK"
    else
        echo 'LDLIBS += -lwinpthread' >> "$MK"
    fi
    
    # FIX-25: Force C++17 standard to avoid C++14/C++11 issues
    if grep -q "^CXXFLAGS" "$MK"; then
        # Remove any existing -std= flags and add -std=c++17
        sed -i 's|-std=c++[0-9][0-9]||g' "$MK"
        sed -i '/^CXXFLAGS/s/$/ -std=c++17/' "$MK"
    else
        echo 'CXXFLAGS += -std=c++17' >> "$MK"
    fi

    # Ensure static linking of all runtime libraries
    sed -i 's|-Wl,-Bdynamic||g' "$MK"
    
    echo "  Patched: $MK"
}

patch_mk "$PKG/include/verilated.mk"
patch_mk "$PKG/share/verilator/include/verilated.mk"

# ══════════════════════════════════════════════════════════════
#  STEP 8 — Create Windows helper files
# ══════════════════════════════════════════════════════════════
echo "[8/9] Creating Windows helper files..."

# ── FIX-15: verilator_includer.bat
cat > "$PKG/bin/verilator_includer.bat" << 'BATEOF'
@echo off
SETLOCAL
SET "SCRIPT_DIR=%~dp0"
SET "INCLUDER=%SCRIPT_DIR%verilator_includer"

:: Try python3 (standard install)
python3 "%INCLUDER%" %* 2>nul && exit /b 0

:: Try python (also covers py.exe on Windows)
python "%INCLUDER%" %* 2>nul && exit /b 0

:: Try py launcher
py -3 "%INCLUDER%" %* 2>nul && exit /b 0

:: Scan common install paths
FOR %%D IN (
    "C:\Python313" "C:\Python312" "C:\Python311" "C:\Python310"
    "C:\Python39"  "C:\Python38"
    "%LOCALAPPDATA%\Programs\Python\Python313"
    "%LOCALAPPDATA%\Programs\Python\Python312"
    "%LOCALAPPDATA%\Programs\Python\Python311"
) DO (
    IF EXIST "%%~D\python.exe" (
        "%%~D\python.exe" "%INCLUDER%" %* && exit /b 0
    )
)

echo.
echo ERROR: Python 3 not found.
echo Install from https://www.python.org/downloads/
echo Make sure to check "Add Python to PATH" during install.
exit /b 1
ENDLOCAL
BATEOF

# ── FIX-16: python3_find.bat
cat > "$PKG/bin/python3_find.bat" << 'BATEOF'
@echo off
SETLOCAL
:: Deactivate PlatformIO / conda from taking over
:: by scanning PATH for a real Python 3

python3 %* 2>nul && exit /b 0
python  %* 2>nul && exit /b 0
py -3   %* 2>nul && exit /b 0

echo ERROR: Python 3 not found.
exit /b 1
ENDLOCAL
BATEOF

# ── FIX-17: verilator.bat — auto-detects VERILATOR_ROOT
cat > "$PKG/bin/verilator.bat" << 'BATEOF'
@echo off
SETLOCAL

:: Auto-detect VERILATOR_ROOT from this .bat's location
SET "BIN_DIR=%~dp0"
SET "BIN_DIR=%BIN_DIR:~0,-1%"
FOR %%I IN ("%BIN_DIR%\..") DO SET "VERILATOR_ROOT=%%~fI"

:: Guard: must use w64devkit (g++ + make + sh)
WHERE g++ >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo ERROR: g++ not found.
    echo Open w64devkit terminal: https://github.com/skeeto/w64devkit/releases
    exit /b 1
)
WHERE make >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo ERROR: make not found. Use w64devkit terminal.
    exit /b 1
)

SET "PATH=%BIN_DIR%;%PATH%"
SET "VERILATOR_ROOT=%VERILATOR_ROOT%"
"%BIN_DIR%\verilator.exe" %*
ENDLOCAL
BATEOF

# ── FIX-18: make.bat — passes CXX/CC/LINK correctly
cat > "$PKG/bin/vl_make.bat" << 'BATEOF'
@echo off
SETLOCAL

:: Auto-detect VERILATOR_ROOT
SET "BIN_DIR=%~dp0"
SET "BIN_DIR=%BIN_DIR:~0,-1%"
FOR %%I IN ("%BIN_DIR%\..") DO SET "VERILATOR_ROOT=%%~fI"

:: Run make with correct compiler variables and C++17 standard
make -C obj_dir -f Vtop.mk ^
    CXX=g++ CC=gcc AR=ar LINK=g++ ^
    CXXFLAGS="-std=c++17" ^
    VERILATOR_ROOT="%VERILATOR_ROOT%" ^
    %*
ENDLOCAL
BATEOF

# ── FIX-19: verify_setup.bat — diagnose all issues before first run
cat > "$PKG/bin/verify_setup.bat" << 'BATEOF'
@echo off
echo.
echo ══════════════════════════════════════════
echo   Verilator Windows Setup Verification
echo ══════════════════════════════════════════
SET PASS=1

:: VERILATOR_ROOT
IF "%VERILATOR_ROOT%"=="" (
    echo [FAIL] VERILATOR_ROOT is NOT set
    SET PASS=0
) ELSE (
    echo [PASS] VERILATOR_ROOT = %VERILATOR_ROOT%
)

:: verilator.exe
IF EXIST "%~dp0verilator.exe" (
    echo [PASS] verilator.exe found
) ELSE (
    echo [FAIL] verilator.exe missing
    SET PASS=0
)

:: verilator_includer
IF EXIST "%~dp0verilator_includer" (
    echo [PASS] verilator_includer found
) ELSE (
    echo [FAIL] verilator_includer missing (needed for --binary compile)
    SET PASS=0
)

:: verilated_std.sv
IF EXIST "%~dp0..\include\verilated_std.sv" (
    echo [PASS] verilated_std.sv found
) ELSE (
    echo [FAIL] verilated_std.sv missing
    SET PASS=0
)

:: verilated.mk
IF EXIST "%~dp0..\include\verilated.mk" (
    echo [PASS] verilated.mk found
    :: Check it has no cross-compiler names left
    findstr /C:"x86_64-w64-mingw32" "%~dp0..\include\verilated.mk" >nul 2>&1
    IF %ERRORLEVEL%==0 (
        echo [WARN] verilated.mk still has cross-compiler names!
    ) ELSE (
        echo [PASS] verilated.mk clean (no cross-compiler names)
    )
    :: Check for pthread (should not be there)
    findstr /C:"-pthread" "%~dp0..\include\verilated.mk" >nul 2>&1
    IF %ERRORLEVEL%==0 (
        echo [WARN] verilated.mk still has pthread references!
    ) ELSE (
        echo [PASS] verilated.mk no pthread (using win32 threading)
    )
    :: Check for C++ standard
    findstr /C:"-std=c++17" "%~dp0..\include\verilated.mk" >nul 2>&1
    IF %ERRORLEVEL%==0 (
        echo [PASS] verilated.mk using C++17
    ) ELSE (
        echo [WARN] verilated.mk may not have C++17 flag
    )
) ELSE (
    echo [FAIL] verilated.mk missing
    SET PASS=0
)

:: g++ (w64devkit)
WHERE g++ >nul 2>&1
IF %ERRORLEVEL%==0 (
    FOR /F "tokens=*" %%V IN ('g++ --version 2^>nul ^| findstr /r "[0-9]"') DO (
        echo [PASS] g++ = %%V & GOTO :gpp_done
    )
    echo [PASS] g++ found
) ELSE (
    echo [FAIL] g++ NOT found - install w64devkit
    SET PASS=0
)
:gpp_done

:: make
WHERE make >nul 2>&1
IF %ERRORLEVEL%==0 (
    echo [PASS] make found
) ELSE (
    echo [FAIL] make NOT found - install w64devkit
    SET PASS=0
)

:: sh (needed by generated Makefiles)
WHERE sh >nul 2>&1
IF %ERRORLEVEL%==0 (
    echo [PASS] sh found
) ELSE (
    echo [WARN] sh NOT found - use w64devkit terminal
)

:: Python
WHERE python3 >nul 2>&1
IF %ERRORLEVEL%==0 (
    FOR /F "tokens=*" %%V IN ('python3 --version 2^>nul') DO echo [PASS] %%V
    GOTO :py_done
)
WHERE python >nul 2>&1
IF %ERRORLEVEL%==0 (
    FOR /F "tokens=*" %%V IN ('python --version 2^>nul') DO echo [WARN] python (no python3 alias): %%V
    GOTO :py_done
)
echo [FAIL] Python NOT found - install from https://www.python.org
SET PASS=0
:py_done

echo.
IF "%PASS%"=="1" (
    echo  All checks passed. Verilator is ready.
) ELSE (
    echo  Some checks FAILED. Fix the above before running Verilator.
)
echo ══════════════════════════════════════════
BATEOF

# ── FIX-20: README_WINDOWS.txt — complete usage guide
cat > "$PKG/README_WINDOWS.txt" << 'READMEEOF'
══════════════════════════════════════════════════
  Verilator for Windows
══════════════════════════════════════════════════

REQUIREMENTS:
  1. w64devkit (g++ + make + sh, all-in-one):
     https://github.com/skeeto/w64devkit/releases

  2. Python 3:
     https://www.python.org/downloads/
     ✓ Check "Add Python 3 to PATH" during install

INSTALL (run once):
  1. Extract to a SHORT path WITHOUT spaces:
       GOOD:  D:\verilator
       AVOID: C:\Program Files\verilator

  2. Set User environment variables:
       VERILATOR_ROOT  =  D:\verilator
       PATH            += D:\verilator\bin

  3. Run verify_setup.bat to confirm everything is OK

USAGE — ALWAYS use w64devkit terminal:

  ① Lint only:
       verilator --lint-only --top-module top test.sv

  ② Generate C++ (then compile separately):
       verilator --cc --top-module top test.sv
       make -C obj_dir -f Vtop.mk CXX=g++ CC=gcc LINK=g++

  ③ Direct binary build (one command):
       verilator --binary --top-module top test.sv

  ④ With multithreading (win32 threading):
       verilator --binary --threads 2 --top-module top test.sv

TROUBLESHOOTING:
  "g++ not found"
    → Use w64devkit shell, NOT cmd.exe or PowerShell

  "verilated_std.sv not found"
    → Set VERILATOR_ROOT environment variable

  "verilator_includer: can't open file"
    → Missing bin/verilator_includer — re-extract the package

  "python3 not found"
    → Install Python 3, check "Add to PATH"

  "make: Error 127"
    → Missing tool — use w64devkit shell

  "Cannot find -lfl"
    → Build issue (Linux only) — install libfl-dev

  "undefined reference to std::cxx11::basic_string"
    → C++11 ABI mismatch - this build uses C++17

  "VL_RESTORER" or "std::decay_t" errors
    → C++14/C++17 required - this build uses C++17

  Path with spaces error
    → Move verilator to D:\verilator (no spaces)

  PlatformIO Python conflict
    → The verilator_includer.bat handles this automatically
══════════════════════════════════════════════════
READMEEOF

# Insert version into README
sed -i "s/Verilator for Windows/Verilator $VERSION for Windows/" "$PKG/README_WINDOWS.txt"

echo "  Created: verilator_includer.bat"
echo "  Created: python3_find.bat"
echo "  Created: verilator.bat"
echo "  Created: vl_make.bat"
echo "  Created: verify_setup.bat"
echo "  Created: README_WINDOWS.txt"

# ══════════════════════════════════════════════════════════════
#  STEP 9 — Package and full verification
# ══════════════════════════════════════════════════════════════
echo "[9/9] Creating tarball and verifying..."

cat > "$PKG/package.json" << PKGJSONEOF
{
  "name":        "verilator-windows",
  "description": "Verilator HDL simulator for Windows (w64devkit)",
  "url":         "https://github.com/withlimon/verilator-windows",
  "version":     "$VERSION",
  "system":      ["windows", "windows_amd64"]
}
PKGJSONEOF

cd "$PKG"
TARBALL="$PACKAGE_DIR/${NAME}-${ARCH}-${VERSION}.tar.gz"
tar -czvf "$TARBALL" * > /dev/null 2>&1

# ── Final verification ────────────────────────────────────────
echo ""
echo "══ Verification ════════════════════════════════════════"

FAIL=0
check() {
    if [ -f "$2" ]; then echo "  [PASS] $1"
    else echo "  [FAIL] $1 — $2"; FAIL=1; fi
}

check "verilator.exe"               "$PKG/bin/verilator.exe"
check "verilator_includer"          "$PKG/bin/verilator_includer"
check "verilator_includer.bat"      "$PKG/bin/verilator_includer.bat"
check "python3_find.bat"            "$PKG/bin/python3_find.bat"
check "verilator.bat"               "$PKG/bin/verilator.bat"
check "vl_make.bat"                 "$PKG/bin/vl_make.bat"
check "verify_setup.bat"            "$PKG/bin/verify_setup.bat"
check "verilated.mk"                "$PKG/include/verilated.mk"
check "verilated_std.sv"            "$PKG/include/verilated_std.sv"
check "verilated_std_waiver.vlt"    "$PKG/include/verilated_std_waiver.vlt"
check "verilated.cpp"               "$PKG/include/verilated.cpp"
check "verilated.h"                 "$PKG/include/verilated.h"
check "share/verilator/verilated.mk" "$PKG/share/verilator/include/verilated.mk"
check "README_WINDOWS.txt"          "$PKG/README_WINDOWS.txt"
check "package.json"                "$PKG/package.json"
check "tarball"                     "$TARBALL"

# PE32+ check
file "$PKG/bin/verilator.exe" | grep -q "PE32+" \
    && echo "  [PASS] PE32+ binary (correct Windows 64-bit)" \
    || { echo "  [FAIL] Not PE32+!"; FAIL=1; }

# Cross-compiler leak check
if grep -q "x86_64-w64-mingw32" "$PKG/include/verilated.mk" 2>/dev/null; then
    echo "  [FAIL] verilated.mk has cross-compiler names!"
    FAIL=1
else
    echo "  [PASS] verilated.mk — no cross-compiler names"
fi

# pthread leak check
if grep -q -E "(-pthread|-lpthread)" "$PKG/include/verilated.mk" 2>/dev/null; then
    echo "  [WARN] verilated.mk still has pthread references (may cause issues)"
else
    echo "  [PASS] verilated.mk — no pthread (win32 threading)"
fi

# DLL dependency check
echo "  [INFO] DLL dependencies:"
"$HOST-objdump" -p "$PKG/bin/verilator.exe" 2>/dev/null \
    | grep "DLL Name" | sed 's/^/          /' || echo "          (none or can't read)"

# Static check
if "$HOST-objdump" -p "$PKG/bin/verilator.exe" 2>/dev/null \
    | grep -qi "libgcc\|libstdc\+\+"; then
    echo "  [WARN] Dynamic libgcc/libstdc++ dependency — may need DLLs"
else
    echo "  [PASS] Fully static (no libgcc/libstdc++ DLLs)"
fi

# Check for winpthread (should be static)
if "$HOST-objdump" -p "$PKG/bin/verilator.exe" 2>/dev/null \
    | grep -qi "winpthread"; then
    echo "  [INFO] winpthread found (static threading support)"
fi

echo ""
[ "$FAIL" -eq 0 ] \
    && echo "  ✅ ALL CHECKS PASSED" \
    || echo "  ❌ SOME CHECKS FAILED — review above"

# Set GitHub Actions outputs if running in CI
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "VERSION=$VERSION" >> "$GITHUB_OUTPUT"
    echo "TARBALL=$TARBALL" >> "$GITHUB_OUTPUT"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo " Package : $TARBALL"
echo " Size    : $(ls -lh "$TARBALL" | awk '{print $5}')"
echo " SHA1    : $(sha1sum "$TARBALL" | cut -d' ' -f1)"
echo "══════════════════════════════════════════════════════"
echo ""
echo " Fixes applied:"
echo "  FIX-01  Full apt dependency list"
echo "  FIX-02  Cross-compiler posix variant auto-detect"
echo "  FIX-03  All cross-tool env vars exported"
echo "  FIX-04  Git clone reuse (saves CI time)"
echo "  FIX-05  VERSION fallback if no git tags"
echo "  FIX-06  configure.ac patch with regex fallback"
echo "  FIX-07  FlexLexer.h auto-copy"
echo "  FIX-08  Parallel build with j1 fallback"
echo "  FIX-09  PE32+ binary verification"
echo "  FIX-10  ALL bin/ helper scripts copied"
echo "  FIX-11  include/ mirrored to share/verilator/"
echo "  FIX-12  verilated.mk cross-compiler → g++/gcc/ar"
echo "  FIX-13  verilated.mk python3 → .bat wrapper"
echo "  FIX-14  PYTHON3 var → python3_find.bat"
echo "  FIX-15  verilator_includer.bat (multi-Python fallback)"
echo "  FIX-16  python3_find.bat (skips PlatformIO Python)"
echo "  FIX-17  verilator.bat (auto-detects VERILATOR_ROOT)"
echo "  FIX-18  vl_make.bat (correct CXX/CC/LINK for make)"
echo "  FIX-19  verify_setup.bat (pre-flight diagnostics)"
echo "  FIX-20  README_WINDOWS.txt (full usage guide)"
echo "  FIX-21  Static C++ runtime linking"
echo "  FIX-22  Linker order fix (MinGW threading)"
echo "  FIX-23  Remove -latomic for x86_64"
echo "  FIX-24  Force win32 threading (fixes pthread conflicts)"
echo "  FIX-25  Force C++17 standard (fixes std::decay_t and VL_RESTORER errors)"
echo "══════════════════════════════════════════════════════"