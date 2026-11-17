#!/bin/sh
# Copyright 2026 Tobi1chi
# SPDX-License-Identifier: Apache-2.0
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
voice_dir="$repo_dir/.build/local-voice"
if [ -s "$voice_dir/lib/libsherpa-onnx-c-api.dylib" ] && [ -s "$voice_dir/lib/libonnxruntime.dylib" ]; then exit 0; fi
case $(uname -m) in arm64) voice_arch=arm64 ;; x86_64) voice_arch=x64 ;; *) exit 1 ;; esac
archive="sherpa-onnx-v2.0.1-osx-$voice_arch-shared-no-tts"
mkdir -p "$voice_dir/lib"
curl -fL --silent --show-error "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$archive.tar.bz2" -o "$voice_dir/runtime.tar.bz2.part"
mv "$voice_dir/runtime.tar.bz2.part" "$voice_dir/runtime.tar.bz2"
tar -xjf "$voice_dir/runtime.tar.bz2" -C "$voice_dir"
cp "$voice_dir/$archive/lib/libsherpa-onnx-c-api.dylib" "$voice_dir/lib/"
cp -L "$voice_dir/$archive/lib/libonnxruntime.dylib" "$voice_dir/lib/"
