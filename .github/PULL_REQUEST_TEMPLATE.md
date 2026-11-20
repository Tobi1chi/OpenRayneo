## Summary / 改动摘要

- What changed and why? / 改了什么、为什么改？
- Related issues / 关联 Issue：`Related: #`（或 `Closes #`）

## Verification / 验证情况

- [ ] CoreAudio C11 ring buffer test (`clang -std=c11 -O2 -Wall -Wextra -Werror -pthread Tests/AudioDriverTests/test_audio_ring.c`)
- [ ] CoreAudio Universal driver build (`sh scripts/build-audio-driver.sh`)
- [ ] macOS Swift build (`swift build`)
- [ ] Android unit tests & build (`cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`)
- [ ] Tested on physical RayNeo iO hardware / 已在实体 RayNeo iO 眼镜真机验证（若未真机验证，请在下方注明边界）

## Known Boundaries / 已知边界

- Mention any environment limits (e.g. tested on Linux/emulator only, not yet verified on real glasses).

## Checklist / 提交前检查

- [ ] No official APKs, firmware binaries, personal recordings, tokens, or signing keys are included / 未包含官方 APK、固件、个人录音、Token 或签名私钥
- [ ] User-facing copy supports bilingual `zh/en` where applicable / 新增界面文案已同步中英文
- [ ] Community contributors are properly credited with `Co-authored-by:` when porting external work / 吸收社区改动时已规范标注 Co-author
