#!/bin/bash
set -euo pipefail

# ===================================================================
# Setup script for Qwen2.5-VL-3B multimodal receipt scanner
#
# This script:
# 1. Clones llama.cpp (latest release)
# 2. Builds an iOS xcframework WITH multimodal (mtmd) support
# 3. Downloads Qwen2.5-VL-3B-Instruct GGUF model + mmproj
#
# Requirements: Xcode 16+, CMake, ~5GB free disk space
# ===================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LLAMA_CLONE_DIR="/tmp/llama-cpp-vlm-build"
XCFW_DEST="$PROJECT_DIR/non-bank/Frameworks/build-apple"

# Model config
MODEL_DIR="$PROJECT_DIR/non-bank/Resources"
MODEL_NAME="Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf"
MMPROJ_NAME="mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf"
HF_REPO="ggml-org/Qwen2.5-VL-3B-Instruct-GGUF"

echo "=== Qwen2.5-VL-3B Multimodal Setup ==="
echo ""

# -------------------------------------------------------
# 1. Clone llama.cpp
# -------------------------------------------------------
if [ -d "$LLAMA_CLONE_DIR/.git" ]; then
    echo "✅ llama.cpp already cloned at $LLAMA_CLONE_DIR"
    echo "   Pulling latest..."
    cd "$LLAMA_CLONE_DIR"
    git pull --ff-only 2>/dev/null || echo "   (pull skipped — detached HEAD or conflict)"
else
    echo "📦 Cloning llama.cpp..."
    rm -rf "$LLAMA_CLONE_DIR"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CLONE_DIR"
fi

cd "$LLAMA_CLONE_DIR"
LLAMA_VERSION=$(git describe --tags --always 2>/dev/null || echo "unknown")
echo "   Version: $LLAMA_VERSION"
echo ""

# -------------------------------------------------------
# 2. Patch build-xcframework.sh to include mtmd
# -------------------------------------------------------
echo "📝 Creating patched build script with mtmd support..."

# We'll build manually instead of using the official script,
# because we need to add mtmd to the library list and headers.

IOS_MIN_OS_VERSION=16.4

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_COMMON=ON
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_METAL=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DLLAMA_OPENSSL=OFF
)

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="$COMMON_C_FLAGS"

# -------------------------------------------------------
# 3. Build for iOS device (arm64)
# -------------------------------------------------------
echo ""
echo "🔨 Building for iOS device (arm64)..."
rm -rf build-ios-device
cmake -B build-ios-device -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="$COMMON_C_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
    -S .
cmake --build build-ios-device --config Release --target ggml llama mtmd -- -quiet
echo "   ✅ iOS device build complete"

# -------------------------------------------------------
# 4. Build for iOS simulator (arm64 + x86_64)
# -------------------------------------------------------
echo ""
echo "🔨 Building for iOS simulator (arm64 + x86_64)..."
rm -rf build-ios-sim
cmake -B build-ios-sim -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator \
    -DCMAKE_C_FLAGS="$COMMON_C_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
    -S .
cmake --build build-ios-sim --config Release --target ggml llama mtmd -- -quiet
echo "   ✅ iOS simulator build complete"

# -------------------------------------------------------
# 5. Create framework structures
# -------------------------------------------------------
echo ""
echo "📦 Creating framework structures..."

create_framework() {
    local build_dir=$1
    local fw_dir="${build_dir}/framework/llama.framework"

    rm -rf "$fw_dir"
    mkdir -p "${fw_dir}/Headers"
    mkdir -p "${fw_dir}/Modules"

    # Copy headers (including mtmd!)
    cp include/llama.h          "${fw_dir}/Headers/"
    cp ggml/include/ggml.h      "${fw_dir}/Headers/"
    cp ggml/include/ggml-opt.h  "${fw_dir}/Headers/"
    cp ggml/include/ggml-alloc.h "${fw_dir}/Headers/"
    cp ggml/include/ggml-backend.h "${fw_dir}/Headers/"
    cp ggml/include/ggml-metal.h "${fw_dir}/Headers/"
    cp ggml/include/ggml-cpu.h  "${fw_dir}/Headers/"
    cp ggml/include/ggml-blas.h "${fw_dir}/Headers/"
    cp ggml/include/gguf.h      "${fw_dir}/Headers/"
    # NEW: multimodal headers
    cp tools/mtmd/mtmd.h        "${fw_dir}/Headers/"
    cp tools/mtmd/mtmd-helper.h "${fw_dir}/Headers/"

    # Module map
    cat > "${fw_dir}/Modules/module.modulemap" << 'MODMAP'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    header "mtmd.h"
    header "mtmd-helper.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
MODMAP

    # Info.plist
    cat > "${fw_dir}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN_OS_VERSION}</string>
</dict>
</plist>
PLIST
}

create_framework "build-ios-device"
create_framework "build-ios-sim"

# -------------------------------------------------------
# 6. Combine static libraries into dynamic framework
# -------------------------------------------------------
echo ""
echo "🔗 Combining static libraries (with mtmd)..."

combine_libs() {
    local build_dir=$1
    local release_dir=$2
    local sdk=$3
    local archs=$4
    local min_version_flag=$5

    local fw_dir="${build_dir}/framework/llama.framework"
    local base_dir="$(pwd)"

    # Collect all static libraries including mtmd
    local libs=(
        "${base_dir}/${build_dir}/src/${release_dir}/libllama.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
    )

    # Find mtmd library (may be in tools/mtmd/ or just mtmd/)
    local mtmd_lib=""
    for candidate in \
        "${base_dir}/${build_dir}/tools/mtmd/${release_dir}/libmtmd.a" \
        "${base_dir}/${build_dir}/tools/mtmd/libmtmd.a" \
        "${base_dir}/${build_dir}/mtmd/${release_dir}/libmtmd.a"; do
        if [ -f "$candidate" ]; then
            mtmd_lib="$candidate"
            break
        fi
    done

    if [ -z "$mtmd_lib" ]; then
        echo "⚠️  libmtmd.a not found! Searching..."
        find "${base_dir}/${build_dir}" -name "libmtmd.a" -o -name "libmtmd-static.a" 2>/dev/null || true
        echo "❌ Cannot find libmtmd.a — multimodal won't work!"
    else
        echo "   Found mtmd: $mtmd_lib"
        libs+=("$mtmd_lib")
    fi

    # Also look for libclip.a (mtmd dependency)
    local clip_lib=""
    for candidate in \
        "${base_dir}/${build_dir}/tools/mtmd/${release_dir}/libclip.a" \
        "${base_dir}/${build_dir}/tools/mtmd/libclip.a"; do
        if [ -f "$candidate" ]; then
            clip_lib="$candidate"
            break
        fi
    done
    if [ -n "$clip_lib" ]; then
        echo "   Found clip: $clip_lib"
        libs+=("$clip_lib")
    fi

    # Combine all into one static lib
    local temp_dir="${base_dir}/${build_dir}/temp"
    mkdir -p "$temp_dir"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2>/dev/null

    # Build arch flags
    local arch_flags=""
    for arch in $archs; do
        arch_flags+=" -arch $arch"
    done

    # Create dynamic library
    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) \
        $arch_flags \
        $min_version_flag \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "@rpath/llama.framework/llama" \
        -o "${fw_dir}/llama"

    # Strip debug symbols
    xcrun strip -S "${fw_dir}/llama"

    rm -rf "$temp_dir"
}

combine_libs "build-ios-device" "Release-iphoneos" "iphoneos" "arm64" \
    "-mios-version-min=${IOS_MIN_OS_VERSION}"

combine_libs "build-ios-sim" "Release-iphonesimulator" "iphonesimulator" "arm64 x86_64" \
    "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"

# Mark device binary correctly
if xcrun -f vtool &>/dev/null; then
    local_fw="build-ios-device/framework/llama.framework/llama"
    xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} \
        -replace -output "$local_fw" "$local_fw"
fi

echo "   ✅ Dynamic libraries created"

# -------------------------------------------------------
# 7. Create XCFramework
# -------------------------------------------------------
echo ""
echo "📦 Creating XCFramework..."
rm -rf build-apple

xcrun xcodebuild -create-xcframework \
    -framework "$(pwd)/build-ios-device/framework/llama.framework" \
    -framework "$(pwd)/build-ios-sim/framework/llama.framework" \
    -output "$(pwd)/build-apple/llama.xcframework"

echo "   ✅ XCFramework created"

# -------------------------------------------------------
# 8. Copy to project
# -------------------------------------------------------
echo ""
echo "📋 Copying to project..."
rm -rf "$XCFW_DEST"
mkdir -p "$XCFW_DEST"
cp -R build-apple/llama.xcframework "$XCFW_DEST/"
echo "   ✅ Copied to $XCFW_DEST/llama.xcframework"

# -------------------------------------------------------
# 9. Download models
# -------------------------------------------------------
echo ""
mkdir -p "$MODEL_DIR"

# Main model
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "✅ Model already exists: $MODEL_NAME"
else
    echo "📦 Downloading $MODEL_NAME (~1.93 GB)..."
    if command -v huggingface-cli &>/dev/null; then
        huggingface-cli download "$HF_REPO" "$MODEL_NAME" \
            --local-dir "$MODEL_DIR" \
            --local-dir-use-symlinks False
    else
        curl -L -o "$MODEL_DIR/$MODEL_NAME" \
            "https://huggingface.co/$HF_REPO/resolve/main/$MODEL_NAME"
    fi
    echo "   ✅ Model downloaded"
fi

# mmproj (multimodal projector)
if [ -f "$MODEL_DIR/$MMPROJ_NAME" ]; then
    echo "✅ mmproj already exists: $MMPROJ_NAME"
else
    echo "📦 Downloading $MMPROJ_NAME (~845 MB)..."
    if command -v huggingface-cli &>/dev/null; then
        huggingface-cli download "$HF_REPO" "$MMPROJ_NAME" \
            --local-dir "$MODEL_DIR" \
            --local-dir-use-symlinks False
    else
        curl -L -o "$MODEL_DIR/$MMPROJ_NAME" \
            "https://huggingface.co/$HF_REPO/resolve/main/$MMPROJ_NAME"
    fi
    echo "   ✅ mmproj downloaded"
fi

# -------------------------------------------------------
# 10. Summary
# -------------------------------------------------------
echo ""
echo "=== Setup Complete ==="
echo ""
echo "llama.cpp version: $LLAMA_VERSION"
echo "XCFramework: $XCFW_DEST/llama.xcframework"
echo "Model: $MODEL_DIR/$MODEL_NAME"
echo "mmproj: $MODEL_DIR/$MMPROJ_NAME"
echo ""
echo "Next steps in Xcode:"
echo ""
echo "1. The xcframework at Frameworks/build-apple/llama.xcframework"
echo "   should already be linked. If not: target → Frameworks → Embed & Sign."
echo ""
echo "2. Models are in non-bank/Resources/ (auto-included by file sync)."
echo "   ⚠️  Total ~2.8 GB — builds will be slower."
echo ""
echo "3. Build & run on a real device (iPhone 12+, iOS 16.4+)."
echo ""
echo "4. .gitignore already excludes *.gguf and Frameworks/"
