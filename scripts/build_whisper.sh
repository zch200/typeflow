#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$ROOT_DIR/Libraries/whisper.cpp"
BUILD_DIR="$WHISPER_DIR/build"
MARKER="$BUILD_DIR/.built"

if [ ! -d "$WHISPER_DIR/src" ]; then
    echo "Error: whisper.cpp not found at $WHISPER_DIR"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

# Required static libraries
REQUIRED_LIBS=(
    "$BUILD_DIR/src/libwhisper.a"
    "$BUILD_DIR/ggml/src/libggml.a"
    "$BUILD_DIR/ggml/src/libggml-base.a"
    "$BUILD_DIR/ggml/src/libggml-cpu.a"
    "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a"
    "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"
)

# Check if rebuild is needed
needs_rebuild=false

if [ ! -f "$MARKER" ]; then
    needs_rebuild=true
else
    # Check submodule commit hash changed
    CURRENT_HASH="$(git -C "$WHISPER_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    BUILT_HASH="$(cat "$MARKER" 2>/dev/null || echo none)"
    if [ "$CURRENT_HASH" != "$BUILT_HASH" ]; then
        echo "whisper.cpp commit changed ($BUILT_HASH → $CURRENT_HASH) — rebuilding..."
        needs_rebuild=true
    fi

    # Check all required static libraries exist
    if [ "$needs_rebuild" = false ]; then
        for lib in "${REQUIRED_LIBS[@]}"; do
            if [ ! -f "$lib" ]; then
                echo "Missing library: $lib — rebuilding..."
                needs_rebuild=true
                break
            fi
        done
    fi
fi

if [ "$needs_rebuild" = false ]; then
    echo "whisper.cpp already built (use 'rm -rf $BUILD_DIR' to force rebuild)"
    exit 0
fi

command -v cmake >/dev/null 2>&1 || { echo "Error: cmake not found. Run: brew install cmake"; exit 1; }

echo "Building whisper.cpp static libraries..."

SDK_PATH="$(xcrun --show-sdk-path)"
CXX_INCLUDE="$SDK_PATH/usr/include/c++/v1"

cmake -S "$WHISPER_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_CXX_FLAGS="-isystem $CXX_INCLUDE" \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF

cmake --build "$BUILD_DIR" --config Release -j"$(sysctl -n hw.logicalcpu)"

git -C "$WHISPER_DIR" rev-parse HEAD > "$MARKER"
echo "whisper.cpp build complete"
