# Tasks: CLI 起動型 GAME BOY エミュレーター(MetalBoy)

**Input**: Design documents from `/specs/001-gb-cli-emulator/`

**Prerequisites**: plan.md(必須)、spec.md(必須)、research.md、data-model.md、contracts/、quickstart.md

**Tests**: 憲法原則 IV(テスト・ファースト/非交渉可能)により、各ユーザーストーリーに
テストタスクを含める。テストは実装前に書き、失敗することを確認してから実装する。

**Organization**: ユーザーストーリーごとに独立実装・独立検証できるようタスクを整理する。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 並列実行可能(異なるファイル・未完了タスクへの依存なし)
- **[Story]**: 属するユーザーストーリー(US1/US2/US3)
- 各タスクの説明には正確なファイルパスを含める

## Path Conventions

- リポジトリ/フォルダ名は `SwiftGB`(憲法技術要件の文書化済み例外)、
  コード内ターゲット・モジュール名は MetalBoy 由来
- paths: `MetalBoy/Sources/{Core,Features,UI,Tools}`、`MetalBoy/Tests/`

---

## Phase 1: Setup(共通基盤)

**Purpose**: プロジェクト初期化と 3 層構成の土台作り

- [X] T001 3 層マルチターゲットの Xcode プロジェクト `MetalBoy/MetalBoy.xcodeproj` を作成する。ターゲットは `MetalBoyCore`(Framework・Objective-C)、`MetalBoyFeatures`(Framework・depends Core)、`MetalBoy`(App・depends Features)、`metalboy-testrom`(CLI ツール・depends Features)の 4 つ
- [X] T002 ビルド設定を `MetalBoy/MetalBoy.xcodeproj` に反映する: macOS 26.0 deployment、ARC、モダン Objective-C(Blocks・Generics・instancetype)、モジュール名は MetalBoy 由来。唯一の言語設定は Objective-C(憲法原則 I)
- [X] T003 [P] ディレクトリ骨格を `MetalBoy/Sources/` 以下に作成する(Core/{CPU,Memory,Video,Audio,Cartridge,Joypad}・Features/{Emulation,Save,Ports}・UI/{App,Window,Audio}・Tools/)と `MetalBoy/Tests/`(Core・Features・UI)

**Checkpoint**: ビルドが成功し、空ターゲット群が依存方向(UI→Features→Core)で繋がっている

---

## Phase 2: Foundational(全ストーリーの前提)

**Purpose**: どのユーザーストーリーにも必要な契約・エラー基盤(この Phase 完了まで
ユーザーストーリーの実装作業に入らない)

- [X] T004 [P] ボタン列挙型 `MBButton`(up/down/left/right/a/b/start/select)と入力ポート契約 `@protocol MBInputPort`(contracts/layer-ports.md のシグネチャ通り)を `MetalBoy/Sources/Features/Ports/MBPorts.h` に宣言する
- [X] T005 [P] 描画ポート `@protocol MBRenderPort`(160x144 RGBA8 フレーム供給)と音声ポート `@protocol MBAudioOutPort`(PCM サンプル供給)を `MetalBoy/Sources/Features/Ports/MBPorts.h` に宣言する。音量はこの契約に含めない(research R-3: 音量は UI 層のゲイン)
- [X] T006 [P] ログフック `@protocol MBLogPort` と `MBLogEvent` 列挙を `MetalBoy/Sources/Features/Ports/MBPorts.h` に追加し、未実装・未確定挙動の記録先を確保する(憲法原則 V)
- [X] T007 エラー基盤を作る: `MetalBoy/Sources/Features/MBErrors.h` に NSError ドメイン・コード体系を定義する。コード分類は FR-011 の原因(引数/ROM 不在/無効 ROM/非対応マッパー/CGB 専用/セーブ失敗)に 1:1 対応させ、CLI 終了コード 1・2 への写像関数も含める(contracts/cli.md 準拠)

**Checkpoint**: ポート契約とエラー分類がコンパイル済み → ユーザーストーリー実装開始可

---

## Phase 3: User Story 1 - ROM を指定して起動しゲームを遊ぶ(Priority: P1)🎯 MVP

**Goal**: 有効な DMG ROM を CLI 引数で受けて起動し、Metal ウィンドウでの画面表示・
固定キー入力・AVAudioEngine による音声でゲームが遊べる

**Independent Test**: ROM パスを渡して実行 → ウィンドウにゲーム画面が出る(SC-001)、
矢印/Z/X/Enter/スペースが反映される(SC-002)、音が鳴る(SC-004)。テスト ROM 合格
(SC-007)でコアの正確性を検証

### Tests for User Story 1(憲法原則 IV: 先行・失敗確認)

- [X] T008 [P] [US1] カートリッジヘッダ解析のユニットテストを `MetalBoy/Tests/Core/MBCartridgeTests.m` に書く。検証項目: `$0143` が CGB 専用フラグ以外で生成を許可・専用フラグは FR-012 により NSError(終了コード 1 相当)・`$0147` が MBC0/1/2/3/5 は許可・範囲外タイプは FR-016 によりエラー・`$0148`/`$0149` から romSize/ramSize 導出(data-model.md の制約通り)
- [X] T009 [P] [US1] CPU のユニットテストを `MetalBoy/Tests/Core/MBCPUTests.m` に書く。検証項目: BIOS なし初期値(research R-5 の DMG 電源投入相当: AF/BC/DE/HL/SP の定型値)、`$0100` からの実行開始、割り込み・タイマの基本挙動
- [X] T010 [P] [US1] PPU のユニットテストを `MetalBoy/Tests/Core/MBPPUTests.m` に書く。検証項目: 160x144 RGBA8 フレームバッファの生成、1 フレーム分のライン進行、BG/ウィンドウ/スプライト合成の最小ケース
- [X] T011 [P] [US1] APU のユニットテストを `MetalBoy/Tests/Core/MBAPUTests.m` に書く。検証項目: チャンネル有効時に PCM サンプルが生成される、無音時は 0 出力、音量フィールドを持たない(research R-3)
- [X] T012 [P] [US1] Joypad のユニットテストを `MetalBoy/Tests/Core/MBJoypadTests.m` に書く。検証項目: MBInputPort からの setButton:pressed: が Joypad レジスタ `$FF00` に 正しく反映、選択行(方向/ボタン)の切替動作
- [X] T013 [P] [US1] セッション駆動の統合テストを `MetalBoy/Tests/Features/MBEmulatorSessionTests.m` に書く。検証項目: run で実時間相当のフレーム駆動が進む(contracts/layer-ports.md の run/stop に準拠)、stop 後はセーブ書出し済みのクリーン状態になる(FR-010 の前段)

### Implementation for User Story 1

- [X] T014 [US1] `MBCartridge` を `MetalBoy/Sources/Core/Cartridge/MBCartridge.{h,m}` に実装する(data-model.md: cartridgeType/romSize/ramSize/hasBattery/isCgbOnly、MBC0/1/2/3/5 のバンク切替を内包。FR-016 準拠。RTC は research R-6 の簡易対応)
- [X] T015 [US1] `MBMemoryMap` を `MetalBoy/Sources/Core/Memory/MBMemoryMap.{h,m}` に実装する: バス結線・WRAM/HRAM/VRAM/OAM/IO 写像、DMG 電源投入相当レジスタ初期化(FR-007: BIOS は扱わない)
- [X] T016 [US1] `MBCPU` を `MetalBoy/Sources/Core/CPU/MBCPU.{h,m}` に実装する: 命令一式、割り込み・タイマ(halt 含む)。T009 のテストで駆動
- [X] T017 [US1] `MBPPU` を `MetalBoy/Sources/Core/Video/MBPPU.{h,m}` に実装する: 160x144 RGBA8 フレームバッファ生成のみ(UI への描画はしない・原則 II)。T010 のテストで駆動
- [X] T018 [US1] `MBApu` を `MetalBoy/Sources/Core/Audio/MBApu.{h,m}` に実装する: 2ch PCM サンプル生成のみ(再生・音量はしない・原則 II)。T011 のテストで駆動
- [X] T019 [US1] `MBJoypad` を `MetalBoy/Sources/Core/Joypad/MBJoypad.{h,m}` に実装する。T012 のテストで駆動
- [X] T020 [US1] `MBEmulatorSession` を `MetalBoy/Sources/Features/Emulation/MBEmulatorSession.{h,m}` に実装する(contracts/layer-ports.md のシグネチャ): ROM 解析 → BIOS なし初期化 → run は実時間(約 59.727fps)駆動、フレーム / PCM を各ポートへ供給
- [X] T021 [US1] UI 層: `MBWindowController` を `MetalBoy/Sources/UI/Window/MBWindowController.{h,m}` に作る。NSWindow + MTKView を MBRenderPort として実装し、スケールなし(生 160x144 ウィンドウ。スケール指定は US2)で等比表示。ピクセル nearest サンプリング(SC-003 の基盤)
- [X] T022 [US1] UI 層: `MBAudioEngine` を `MetalBoy/Sources/UI/Audio/MBAudioEngine.{h,m}` に作る。AVAudioEngine で MBAudioOutPort を実装し、既定 50% ゲイン(US2 で可変化)
- [X] T023 [US1] UI 層: エントリポイント `MetalBoy/Sources/UI/App/main.m` と `MBAppDelegate` を作る。ROM 1 本引数でセッション生成 → ウィンドウ・音声接続 → run。NSEvent(矢印/Z/X/Enter/スペース、FR-008 固定)を MBInputPort へ写像
- [X] T024 [US1] 仕上げ統合: `MetalBoy/Sources/UI/App/MBAppDelegate.m` で US1 のフローを接続し、ROM 未指定時の引数エラー(終了コード 2)への先行接続も用意(US3 で詳細化)

**Checkpoint**: US1 が独立して動く(ROM 一本で起動 → 操作・音・画面)。SC-001/002/004/007 の受け手が揃う

---

## Phase 4: User Story 2 - 起動引数でオプションを指定する(Priority: P2)

**Goal**: `--scale`(1〜8 既定 3)と `--volume`(0〜100 既定 50)を CLI 引数で
指定でき、範囲外は既定値フォールバックなしで失敗する

**Independent Test**: 同一 ROM を複数オプション組合せで起動し、見た目のサイズと
音量の変化を確認(SC-003 / SC-004)。範囲外値で即エラー(FR-005)

### Tests for User Story 2

- [X] T025 [P] [US2] オプション解析のユニットテストを `MetalBoy/Tests/Features/MBOptionParserTests.m` に書く。検証項目: 既定(scale=3, volume=50)、1〜8/0〜100 の通過、`--scale 0/9/abc` `--volume 150/-1` が FR-005 通りのエラー、重複指定は最後優先、ROM 未指定/複数位置引数/未知オプションは終了コード 2 分類(contracts/cli.md 準拠)

### Implementation for User Story 2

- [X] T026 [US2] `MBOptionParser` を `MetalBoy/Sources/Features/MBOptionParser.{h,m}` に実装する(contracts/layer-ports.md のシグネチャ)。検証は T025 で駆動し、既定値フォールバックは実装しない(FR-005)
- [X] T027 [US2] ウィンドウへのスケール反映: `MetalBoy/Sources/UI/Window/MBWindowController.m` を拡張し、MBLaunchOptions.scale(1〜8)で MTKView の描画矩形を等比拡大(整数倍のみ。SC-003)
- [X] T028 [US2] 音量の反映: `MetalBoy/Sources/UI/Audio/MBAudioEngine.m` を拡張し、MBLaunchOptions.volumePercent(0〜100)を AVAudioEngine 出力ゲインに写像。0% は完全無音(SC-004 / FR-009)
- [X] T029 [US2] main の接続: `MetalBoy/Sources/UI/App/main.m` で MBOptionParser の結果を MBEmulatorSession へ渡し、解析エラー時は stderr 1 行 + 終了コードで即終了(FR-011。contracts/cli.md)

**Checkpoint**: US2 が独立して動く(オプションで見た目・音量が変わり、不正値は即エラー)

---

## Phase 5: User Story 3 - クリーンな終了・明確なエラー・セーブデータ(Priority: P3)

**Goal**: ウィンドウ閉じ / Ctrl+C のクリーン終了、全エラーパスの確立、
セーブ対応カートリッジの `.sav` 保存・復元

**Independent Test**: 正常入力と各異常入力で起動を試みて終了挙動とメッセージ・
失敗速度(SC-005)を確認。セーブ→終了→再起動→復元の正式工程(US3 受け入れ 2)

### Tests for User Story 3

- [X] T030 [P] [US3] セーブファイルのユニットテストを `MetalBoy/Tests/Features/MBSaveFileTests.m` に書く。検証項目: path が `<ROM ベース名>.sav`(ROM と同じディレクトリ)、load は無ければ nil でエラーなし、saveData: は SRAM 生バイトを書く、サイズ不一致/読取不能は NSError(research R-7: 黙って上書きしない)、セーブ非対応では何もしない(FR-014)
- [X] T031 [P] [US3] エラー分類の統合テストを `MetalBoy/Tests/UI/MBErrorPresentationTests.m` に書く。検証項目: FR-011 の各原因が stderr 1 行の日本語 + 正しい終了コードに写像される(contracts/cli.md のメッセージ形式・1 秒以内の失敗)

### Implementation for User Story 3

- [X] T032 [US3] `MBSaveFile` を `MetalBoy/Sources/Features/Save/MBSaveFile.{h,m}` に実装する(contracts/layer-ports.md のシグネチャ: loadWithError: / saveData:)。読み書きは NSData レベル(Feature 層のみ・ファイルシステムのみ)
- [X] T033 [US3] セーブ復元・書出しの統合: `MetalBoy/Sources/Features/Emulation/MBEmulatorSession.m` で、起動時は ROM.hasBattery のときのみ MBSaveFile.loadWithError: を呼んで MBCartridge restoreRAM: し、終了時は currentRAM を書き出す(FR-013)。hasBattery=NO はスキップ(FR-014)
- [X] T034 [US3] クリーン終了の実装: `MetalBoy/Sources/UI/App/MBAppDelegate.m` にウィンドウ閉じ(終了コード 0)と SIGINT(Ctrl+C)→ stop 経由のクリーン終了(セーブ書出し → リソース解放。FR-010 / contracts/cli.md の Ctrl+C 挙動)を入れる
- [X] T035 [US3] エラー提示の実装: `MetalBoy/Sources/UI/App/MBAppDelegate.m` で T007 の分類を stderr 出力へ結線し、ROM 不在・無効 ROM・CGB 専用・非対応マッパー・セーブ失敗・GUI 利用不可の各メッセージを 1 行日本語で出す(FR-011)

**Checkpoint**: 全ユーザーストーリーが独立して機能する(US3 完了で仕様の FR-001〜FR-016 が全て実挙動になる)

---

## Phase 6: Polish & Cross-Cutting(横断)

**Purpose**: 複数ストーリーに跨る品質・検証・文書

- [X] T036 [P] テスト ROM ランナーを実装する: `MetalBoy/Sources/Tools/metalboy_testrom.{h,m}` と main を作り、blargg 系スイート ROM を実行して合格/不合格と診断文字列を報告する(research R-9。収集結果は SC-007 の基準: 合格率 100%)
- [X] T037 [P] 標準テストスイート一覧を `specs/001-gb-cli-emulator/quickstart.md` の「SC-007」節に紐づく形で `MetalBoy/Tests/TEST-ROMS.md` に文書化し、ROM パスの外部指定方式を明記する
- [X] T038 セーブファイル破損時の挙動を確定・実装: `MetalBoy/Sources/Features/Save/MBSaveFile.m` に、サイズ不一致・読取不能からの NSError 起動失敗仕様(research R-7 既定)の単体テストを `MetalBoy/Tests/Features/MBSaveFileTests.m` に追加して貫通させる(spec Edge Cases の決着)
- [X] T039 quickstart.md に沿って全検証シナリオを実行し、SC-001〜SC-007 をパスさせる。fail したら該当タスクへ戻って修正(spec 完了条件)
- [X] T040 [P] ドキュメント整備: `docs/architecture.md` に 3 層の依存方向・ポート契約・macOS 26+ 専用の理由・他 OS/SDL 接続の接点(原則 VI)を日本語でまとめる

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup(Phase 1)**: 依存なし。即開始可
- **Foundational(Phase 2)**: Setup 完了後。全ユーザーストーリーを BLOCK
- **US1(Phase 3)**: Foundational 完了後に開始。他ストーリーに非依存
- **US2(Phase 4)**: Foundational 完了後に開始可。US1 のウィンドウ・音声実体へ
  引数を接続するため、実質は US1 の T021/T022 完了後に統合完了する
- **US3(Phase 5)**: Foundational 完了後に開始可。US1 のセッション実装(T020)と
  US2 のパーサ(T026)を消費するため、統合タスク(FR-013/FR-011 接線)は後発
- **Polish(Phase 6)**: 全ストーリー完了後

### User Story Dependencies

- **US1(P1)**: Foundational のみで成立する最短経路。MVP 核心
- **US2(P2)**: US1 の画面・音声の「見た目の変化」として完成する。US1 単体でも
  既定値(x3/50%)で動くため、独立性は保たれる
- **US3(P3)**: US1 のセッション・US2 のパーサを利用するが、エラー分類
  (T007)は Foundational で先行。セーブ実装は US1 のカートリッジ API に依存

### Within Each User Story

- テストを先に書き、FAIL 確認 → 実装(spec/憲法 IV)
- Core コンポーネント → Features セッション → UI 統合の順
- 各ストーリーの Checkpoint で独立検証

### Parallel Opportunities

- Phase 1 の T003、Phase 2 の T004/T005/T006 は並列可
- 各ストーリーのテストタスク(T008〜T013、T025、T030/T031)はファイルが
  異なるため並列可
- US1 内では Core コンポーネント(PPU/APU/Joypad/MBCartridge)が独立ファイル
  なので、T014 〜 T019 のうち契約が固まり次第並列化可
- T036 と T037 と T040(横断)は US3 後に並列可

---

## Parallel Example: User Story 1

```bash
# Core コンポーネント(T016 骨格確定後、独立ファイルとして並列):
Task: "MBCartridge を MetalBoy/Sources/Core/Cartridge/ に実装"
Task: "MBPPU を MetalBoy/Sources/Core/Video/ に実装"
Task: "MBApu を MetalBoy/Sources/Core/Audio/ に実装"
Task: "MBJoypad を MetalBoy/Sources/Core/Joypad/ に実装"

# テスト(TDD 順守のため先に全 FAIL 確認):
Task: "Tests/Core/MBCartridgeTests.m"
Task: "Tests/Core/MBCPUTests.m"
Task: "Tests/Core/MBPPUTests.m"
```

---

## Implementation Strategy

### MVP First(US1 のみ)

1. Phase 1 完了 → 2. Phase 2 完了(前提整う)→ 3. Phase 3 完了(US1)
4. **STOP & VALIDATE**: quickstart.md の SC-001/002/004/007 相当を独立確認
5. ここで既に「遊べるエミュレーター」として価値が届く

### Incremental Delivery

1. Setup + Foundational → 基盤 ready
2. US1 追加 → 独立検証(Playable MVP)
3. US2 追加 → 独立検証(オプション対応)
4. US3 追加 → 独立検証(エラー・セーブ・終了)
5. Polish → テスト ROM 合格 → リリース可

### Parallel Team Strategy

- 実装担当 A: US1 コア(CPU/PPU/APU/Joypad)
- 実装担当 B: US1 UI(UI ウィンドウ・音声・接線)+ US2
- 実装担当 C: US3(セーブ・エラー・終了)+ 横断テスト
- Foundational のポート契約が並列前提(各は T004〜T007 の署名を守る)

---

## Notes

- [P] は「異なるファイル・未完了タスク無し」の意
- コミット・レビューコメント・ドキュメントは日本語(憲法)。コード識別子は英語
- 各タスク完了後(または論理的な塊ごと)にコミット
- Test First: 対応する .m 実装前にテスト MUST FAIL 確認(憲法 IV)
- Checkpoint で仕様の該当受け入れシナリオを通す(spec 別記)
- やってはならない: コア層への AppKit 侵入(原則 VI)・既定値
  フォールバック(FR-005)・キー割当変更(FR-008)・オプション永続化(FR-006)

## Phase 7: Convergence

- [X] T041 CRITICAL: 未実装・未確定挙動(未知オペコード・未対応 IO 書込み等)を `MBLogPort logEvent:message:` へ記録する経路を `MetalBoy/Sources/Core/CPU/MBCPU.m` → `MetalBoy/Sources/Features/Emulation/MBEmulatorSession.m` に結線し、`logPort` が実際に呼ばれることを単体テストで確認する per Constitution V (missing)
- [X] T042 CRITICAL: tracing / デバッグ用の CLI 出力(stdout、人間可読と機械可読 JSON の両対応)を `metalboy-testrom` に追加する(例: `--json` で結果・シリアル出力・ログイベントを JSON 出力)per Constitution V (missing)
- [X] T043 メインメニュー(`installMainMenu`)を削除し、Cmd+Q による終了は `MetalBoy/Sources/UI/App/MBAppDelegate.m` のキーモニタで `[NSApp terminate:]` を呼ぶ方式に置き換える per FR-002 (contradicts)
- [X] T044 BIOS 読込み経路(`MBGameBoy.bootROMData`・`metalboy-mooneye --bios`)を製品経路(MetalBoy アプリ・MBEmulatorSession)から到達不能であることを確認し、開発ツール限定の例外として spec 側での扱いをレビュー・判断する per FR-007 (contradicts)
- [X] T045 blargg mem_timing(01/02/03)と halt_bug を `metalboy-testrom` で実行し、合格を `MetalBoy/Tests/TEST-ROMS.md` に記録する per SC-007 (partial)
