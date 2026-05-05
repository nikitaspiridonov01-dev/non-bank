#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

echo "=== Receipt Scanner Setup ==="
echo ""

# -------------------------------------------------------
# 1. Download llama.cpp XCFramework
# -------------------------------------------------------
LLAMA_VERSION="b8747"
XCFW_DIR="$PROJECT_DIR/Frameworks"
XCFW_PATH="$XCFW_DIR/llama.xcframework"

if [ -d "$XCFW_PATH" ]; then
    echo "✅ llama.xcframework already exists at $XCFW_PATH"
else
    echo "📦 Downloading llama.cpp $LLAMA_VERSION xcframework..."
    mkdir -p "$XCFW_DIR"
    XCFW_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}/llama-${LLAMA_VERSION}-xcframework.zip"

    echo "   URL: $XCFW_URL"
    curl -L -o "$XCFW_DIR/llama-xcframework.zip" "$XCFW_URL"

    echo "   Extracting..."
    cd "$XCFW_DIR"
    unzip -qo llama-xcframework.zip
    rm llama-xcframework.zip
    cd "$PROJECT_DIR"

    if [ -d "$XCFW_PATH" ]; then
        echo "✅ llama.xcframework downloaded and extracted"
    else
        echo "⚠️  xcframework not found after extraction. Check the zip contents:"
        ls -la "$XCFW_DIR/"
        echo ""
        echo "You may need to rename the extracted folder to 'llama.xcframework'"
    fi
fi

# -------------------------------------------------------
# 2. Download Qwen2.5-1.5B-Instruct GGUF model
# -------------------------------------------------------
MODEL_NAME="qwen2.5-1.5b-instruct-q4_k_m.gguf"
MODEL_DIR="$PROJECT_DIR/non-bank/Resources"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

if [ -f "$MODEL_PATH" ]; then
    echo "✅ GGUF model already exists at $MODEL_PATH"
else
    echo ""
    echo "📦 Downloading Qwen2.5-1.5B-Instruct Q4_K_M (~1.12 GB)..."
    echo "   This may take a few minutes depending on your connection."
    mkdir -p "$MODEL_DIR"

    if command -v huggingface-cli &> /dev/null; then
        huggingface-cli download Qwen/Qwen2.5-1.5B-Instruct-GGUF \
            "$MODEL_NAME" \
            --local-dir "$MODEL_DIR" \
            --local-dir-use-symlinks False
    else
        echo "   huggingface-cli not found, using curl..."
        curl -L -o "$MODEL_PATH" \
            "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/$MODEL_NAME"
    fi

    if [ -f "$MODEL_PATH" ]; then
        echo "✅ GGUF model downloaded"
    else
        echo "❌ Model download failed. Download manually:"
        echo "   huggingface-cli download Qwen/Qwen2.5-1.5B-Instruct-GGUF $MODEL_NAME --local-dir $MODEL_DIR"
    fi
fi

# -------------------------------------------------------
# 3. Summary
# -------------------------------------------------------
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps in Xcode:"
echo ""
echo "1. FRAMEWORK: Drag '$XCFW_DIR/llama.xcframework' into your"
echo "   Xcode project → target 'non-bank' → General → Frameworks,"
echo "   Libraries and Embedded Content → set 'Embed & Sign'."
echo ""
echo "2. MODEL: The model file is in non-bank/Resources/ which is"
echo "   auto-included by the file-system-synchronized build group."
echo "   ⚠️  The model is ~1.12 GB — builds will be slower."
echo "   For dev: consider loading from Documents dir instead."
echo ""
echo "3. BUILD & RUN: Open non-bank.xcodeproj, build for a real device"
echo "   (iPhone 12+). Go to Settings → Receipt Scanner to test."
echo ""
echo "4. .gitignore: Add these lines to avoid committing large files:"
echo "   *.gguf"
echo "   Frameworks/"
