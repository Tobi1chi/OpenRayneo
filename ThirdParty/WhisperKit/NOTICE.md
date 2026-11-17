# WhisperKit and local Whisper ASR

- WhisperKit / Argmax OSS Swift **1.1.1**, Argmax, MIT: https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.1. LICENSE and third-party NOTICES are retained. Package.resolved records Swift dependencies.
- Whisper tiny multilingual, OpenAI, MIT: https://github.com/openai/whisper. Model license retained as WHISPER-LICENSE.
- Core ML conversion: https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-tiny. Tokenizer files: https://huggingface.co/openai/whisper-tiny. These downloaded artifacts are kept in Application Support/OpenRayneo/LocalASR, outside Git and outside the app bundle. No voice data is used for downloading.
- Mel computation is CPU-only; encoder and decoder are configured with Core ML cpuAndNeuralEngine. Core ML selects actual supported execution devices; no claim of exclusive NPU execution or measured power savings is made.
