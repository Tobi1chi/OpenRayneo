# Local speech models

OpenRayneo uses the following unchanged pretrained models and Android/macOS runtimes. The model binaries and AAR are downloaded by `scripts/prepare-android-voice.sh`; they are not committed. macOS uses the same model files and sherpa-onnx 2.0.1 C API/ONNX Runtime, downloaded by `scripts/prepare-mac-voice.sh`; the bundled public C header is retained under `Sources/CSherpaOnnx` with its original copyright. This build does not train or fine-tune these models.

- **sherpa-onnx 2.0.1** Android AAR, k2-fsa contributors, Apache-2.0. [Release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.1), license in `LICENSE`.
- **3D-Speaker CAM++ Chinese 16k common** speaker embeddings, Alibaba DAMO/3D-Speaker contributors, Apache-2.0. [Model card](https://modelscope.cn/models/iic/speech_campplus_sv_zh-cn_16k-common), [project](https://github.com/modelscope/3D-Speaker). Export distributed by [sherpa speaker recognition models](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models), filename `3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx`. License in `CAMPLUS-LICENSE`.
- **Silero VAD** ONNX, Silero Team, MIT. [Upstream](https://github.com/snakers4/silero-vad), [distributed export](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models), filename `silero_vad.onnx`. License in `SILERO-LICENSE`.
- **pyannote segmentation 3.0**, CNRS, MIT. [Original model/license](https://huggingface.co/pyannote/segmentation-3.0), [sherpa int8 conversion](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models), archive `sherpa-onnx-pyannote-segmentation-3-0.tar.bz2`, member `model.int8.onnx`. The export archive's license is retained as `SEGMENTATION-LICENSE`; original model license is in `SEGMENTATION-MODEL-LICENSE`.
- **ONNX Runtime**, Microsoft contributors, MIT, included in the sherpa runtime. License in `ONNXRUNTIME-LICENSE`; upstream [license](https://github.com/microsoft/onnxruntime/blob/main/LICENSE).

Assets: `voice-models/campplus-zh-16k.onnx`, `silero-vad.onnx`, `segmentation.int8.onnx`. Runtime uses one CPU thread per model. All feature extraction and matching happen on the device; model files do not contain user voiceprints. Voiceprints use the separate model identifier `campplus-zh-16k-common/sherpa-2.0.1`.

The downloaded model names are pinned. The upstream release tags containing model exports are mutable, so this build process records the source URLs rather than claiming immutable byte-for-byte reproducibility. No additional file hashes are used.
