#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
voice_assets="$repo_dir/android/app/src/main/assets/voice-models"
voice_libs="$repo_dir/android/app/libs"
mkdir -p "$voice_assets" "$voice_libs"
fetch() {
    if [ ! -s "$2" ]; then
        curl -fL --silent --show-error "$1" -o "$2.part"
        mv "$2.part" "$2"
    fi
}
if [ "${OPENRAYNEO_VOICE_MODELS_ONLY:-0}" != 1 ]; then
    fetch https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-2.0.1.aar "$voice_libs/sherpa-onnx-2.0.1.aar"
fi
fetch https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx "$voice_assets/campplus-zh-16k.onnx"
fetch https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx "$voice_assets/silero-vad.onnx"
if [ ! -s "$voice_assets/segmentation.int8.onnx" ]; then
    voice_cache="$repo_dir/.build/android-voice-models"
    mkdir -p "$voice_cache"
    fetch https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 "$voice_cache/segmentation.tar.bz2"
    tar -xOf "$voice_cache/segmentation.tar.bz2" sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx > "$voice_assets/segmentation.int8.onnx.part"
    mv "$voice_assets/segmentation.int8.onnx.part" "$voice_assets/segmentation.int8.onnx"
fi
