# MetalBoy アーキテクチャ

CLI 起動型 DMG(GAME BOY)エミュレーターの 3 層構成とポート契約の概要。
仕様・設計の詳細は `specs/001-gb-cli-emulator/` を参照。

## 全体構成

```
MetalBoy(app: AppKit + MetalKit + AVFAudio)
   │  起動引数解析 → セッション生成 → ポート接続 → run
   ▼
MetalBoyFeatures(static lib: セッション・オプション・セーブ・エラー)
   │  MBEmulatorSession / MBOptionParser / MBLaunchOptions
   │  MBSaveFile / MBErrors / MBPorts.h(ポート契約)
   ▼
MetalBoyCore(static lib: DMG 相当の純粋コア)
   ├─ CPU/MBCPU(命令一式・割り込み・halt)
   ├─ Memory/MBGameBoy(MBCPUBus 実装)・MBMemoryMap(バス全域)
   ├─ Cartridge/MBCartridge(MBC0/1/2/3/5 + RTC 簡易)
   ├─ Video/MBPPU(160x144 RGBA8 フレームバッファ)
   ├─ Audio/MBApu(4ch → 48kHz ステレオ int16 PCM)
   └─ Joypad/MBJoypad($FF00 P1)
```

### 依存方向(憲法原則 I/VI)

- `UI → Features → Core` の一方向。Core は AppKit/Foundation の UI 部分に非依存
  (メモリ管理に Foundation は使用するが、ウィンドウや描画には触れない)
- UI 層(`Sources/UI`)は macOS 26 でのみ動く。Features/Core は SDL 等の別
  フロントエンドに再利用できる(ポート契約を実装し直すだけ)

## ポート契約(`Sources/Features/Ports/MBPorts.h`)

UI ↔ Features の境界は 4 つのプロトコルで定義する。セッションはポートを
property で受け、UI 実装に依存しない(ヘッドレスでは nil 許容):

| プロトコル | 役割 | 補足 |
|-----------|------|------|
| `MBInputPort` | `setButton:pressed:` でボタン押下を通知 | 列挙 `MBButton`(up/down/left/right/a/b/start/select) |
| `MBRenderPort` | `presentFramebuffer:` で 160x144 RGBA8 を供給 | Core→UI 方向・コールバック |
| `MBAudioOutPort` | `enqueueSamples:count:` で int16 ステレオ PCM を供給 | 音量適用は UI 側(research R-3) |
| `MBLogPort` | `logEvent:message:` 未実装挙動の記録先 | 憲法原則 V(簡略決済の記録) |

### 駆動モデル

- `MBGameBoy` が `MBCPUBus` を実装。`cpu stepWithBus:` は消費 M-cycle 数を返し、
  呼び出し側が `cpuTickCycle` を同回数呼ぶ(1 M-cycle = 4 dots)
- `cpuTickCycle` 内で `memory tickCycle`(timer/serial)+ `ppu tickDots:4` +
  `apu tickDots:4` を進め、IF 要求を `memory.ifRegister` に反映
- `MBEmulatorSession` がフレーム境界で `presentFramebuffer:` と
  `enqueueSamples:` を呼び、実時間(59.727fps)でペースする(`run`)。
  `runFrames:` は実時間を待たない headless 駆動(テスト ROM 用)

## CLI 契約(`contracts/cli.md`)

```
MetalBoy [--scale 1-8] [--volume 0-100] <rom-path>
```

- 既定値: スケール x3・音量 50%。範囲外は **既定値へフォールバックせず即失敗**(FR-005)
- 終了コード(contracts/cli.md): `0`=正常、`1`=ランタイムエラー、`2`=引数エラー
- 診断は stderr へ 1 行の日本語(`MBUserFacingMessageForError`)
- キー割当は固定(FR-008): 矢印=十字キー / Z=B / X=A / Enter=Start / スペース=Select
- オプションの永続化はしない(毎回引数で指定)

## セーブ(`MBSaveFile` / FR-013/FR-014)

- `.sav` は ROM と同じディレクトリの `<ROM ベース名>.sav`。内容は SRAM 生ダンプ
- `hasBattery` のカートリッジのみ対象。起動時に復元、終了時に書出し
- サイズ不一致・読取不能は黙って上書きせず **起動失敗**(research R-7)

## macOS 26 専用の理由と移植接点(原則 VI)

- AppKit のモダン API(MTKView・AVAudioSourceNode・NSEvent モニタ)と
  SDK 27 固有の挙動(NSError キー名の変化等)に UI 層が寄与する
- Core/Features は Foundation のみで書かれており、SDL/DirectX 等への移植では
  5 つのポート契約を再実装するだけで済む:
  `MBInputPort` / `MBRenderPort` / `MBAudioOutPort` / `MBLogPort` /
  (`MBEmulatorSession` 自体)

## ビルド

```sh
cd MetalBoy
xcodegen generate          # project.yml から MetalBoy.xcodeproj を再生成
xcodebuild -project MetalBoy.xcodeproj -scheme MetalBoy -configuration Debug build
xcodebuild -project MetalBoy.xcodeproj -scheme MetalBoy -destination 'platform=macOS' test
```
