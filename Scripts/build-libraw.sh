#!/bin/bash
set -euo pipefail
mkdir -p Vendor/lib
if [ ! -d Vendor/LibRaw ]; then git clone --depth 1 --branch 0.22.3 https://github.com/LibRaw/LibRaw.git Vendor/LibRaw; fi
cd Vendor/LibRaw
if [ -f Makefile ]; then make distclean; fi
autoreconf -fi
PLATFORM=iphoneos;ARCH=arm64;MINFLAG=-miphoneos-version-min=17.0
if [ "${1:-device}" = "simulator" ]; then PLATFORM=iphonesimulator;ARCH=$(uname -m);MINFLAG=-mios-simulator-version-min=17.0; fi
SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
export CC="$(xcrun --sdk "$PLATFORM" -f clang)"
export CXX="$(xcrun --sdk "$PLATFORM" -f clang++)"
export CFLAGS="-arch $ARCH -isysroot $SDK $MINFLAG -O2"
export CXXFLAGS="$CFLAGS -std=c++17"
export LDFLAGS="-arch $ARCH -isysroot $SDK $MINFLAG"
./configure --host="$ARCH-apple-darwin" --disable-shared --enable-static --disable-examples --disable-openmp --disable-lcms --disable-jpeg
make -j3
cp lib/.libs/libraw.a ../lib/
