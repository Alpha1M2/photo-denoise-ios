#!/bin/bash
set -euo pipefail
mkdir -p Vendor/lib
git clone --depth 1 --branch 0.22.3 https://github.com/LibRaw/LibRaw.git Vendor/LibRaw
cd Vendor/LibRaw
autoreconf -fi
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0 -O2"
export CXXFLAGS="$CFLAGS -std=c++17"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0"
./configure --host=aarch64-apple-darwin --disable-shared --enable-static --disable-examples --disable-openmp --disable-lcms --disable-jpeg
make -j3
cp lib/.libs/libraw.a ../lib/
