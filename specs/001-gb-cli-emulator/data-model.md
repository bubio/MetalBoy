# Data Model: CLI 起動型 GAME BOY エミュレーター（MetalBoy）

**Branch**: `001-gb-cli-emulator` | **Date**: 2026-10-18

機能仕様の Key Entities（起動オプション / ROM ファイル / キー割り当て /
セーブファイル）を設計の観点で具体化したもの。層の所属を明示する
（Core = エミュレーションコア層 / Features = 機能層 / UI = UI 層）。

## エンティティ

### MBLaunchOptions（Features）

CLI 起動引数の解析結果。プロセス 1 回の寿命のみ有効（FR-006）。

| フィールド | 型 | 制約 / 既定値 |
|---|---|---|
| romPath | NSString | 必須。存在する読み取り可能なファイルパス |
| scale | NSUInteger | 1〜8（FR-003）。範囲外は解析失敗。既定 3 |
| volumePercent | NSUInteger | 0〜100（FR-004）。範囲外は解析失敗。既定 50 |

検証ルール: どれか 1 つでも違反すれば`MBOptionError`(理由つき)を返し、
既定値へのフォールバックは行わない（FR-005）。ROM 未指定も解析失敗。

### MBCartridgeROM（Core）

ROM ファイルの解析結果（読み取り専用）。

| フィールド | 型 | 制約 |
|---|---|---|
| data | NSData | 生 ROM イメージ。サイズは 32KB/64KB/128KB/… の 2 の累乗 |
| cartridgeType | MBCartridgeType | ヘッダ `$0147` から判定。MBC0/1/2/3/5 のみ許容（FR-016） |
| romSize / ramSize | NSUInteger | ヘッダ `$0148` / `$0149` |
| hasBattery | BOOL | タイプから導出。セーブファイルの対象か（FR-013/FR-014） |
| isCgbOnly | BOOL | ヘッダ `$0143`。専用フラグ相当 TRUE の場合 TRUE（判定詳細は tasks 実装時の仕様確定事項） |

検証ルール: ヘッダサイズ不足・不正タイプは起動失敗（FR-011）。

### MBCartridgeRAM（Core）

カートリッジの SRAM（セーブ領域）のランタイム表現。

| フィールド | 型 | 制約 |
|---|---|---|
| bytes | NSMutableData（ramSize 長） | SRAM 非対応タイプでは常に空 |
| dirty | BOOL | 内容変更の有無。終了時の書き出し判断に使用 |

状態遷移: `未読込 → 読込済(.sav からの復元 or 初期化) → 稼働中（ゲームが
書込み） → 終了時に書出し`。セーブファイルが存在するがサイズ不一致/読取不能の場合は
起動失敗（research R-7）。

### MBSaveFile（Features）

`.sav` ファイルの読み書きを担うロジック（データそのものは
MBCartridgeRAM.bytes と 1:1 対応）。

| フィールド | 型 | 制約 |
|---|---|---|
| path | NSString | `<ROM ベース名>.sav`（ROM と同じディレクトリ） |
| length | NSUInteger | MBCartridgeROM.ramSize と一致しなければならない |

操作: `loadPath:error:`（起動時）/ `writeWithBytes:`（終了時）。
セーブ非対応カートリッジでは読み書き自体を行わずエラーにもしない（FR-014）。

### MBEmulatorState（Core）

エミュレータの実行時状態（UI に持ち出されるのはフレーム/PCM のみ）。

| フィールド | 型 | 備考 |
|---|---|---|
| cpu | MBCPU | レジスタ・タイマ・割り込み状態 |
| memory | MBMemoryMap | WRAM/HRAM/VRAM/OAM/IO |
| ppu | MBPPU | 160×144 RGBA フレームバッファの生成 |
| apu | MBApu | 2ch PCM サンプルの生成（音量は保持しない） |
| cartridge | MBCartridge | ROM + RAM + MBC コントローラ |

ライフサイクル: `停止 → 起動（BIOS なし初期化, FR-007）→ 稼働中 → 終了
（リソース解放, FR-010）`。ポーズ状態は存在しない（FR-015）。

### MBKeyMapping（UI）

キー → ボタンの固定対応表（FR-008）。

| キー | ボタン |
|---|---|
| 上 / 下 / 左 / 右（矢印） | D-Pad（↑↓←→） |
| Z / X | B / A |
| Enter（Return） | Start |
| Space | Select |

変更不可。UI のキーダウン/キーアップイベントを MBInputPort へ写像する。

### MBInputPort / MBRenderPort / MBAudioOutPort（Features: 抽象ポート）

UI 実装と機能層をつなぐ契約（詳細は contracts/layer-ports.md）。

- MBInputPort: ボタン単位の pressed/released 通知（Joypad レジスタへ反映）
- MBRenderPort: コアが生成したフレームバッファの供給受付
- MBAudioOutPort: コアが生成した PCM サンプルの供給受付

UI 層の実装: MTKView 描画（MBRenderPort）、AVAudioEngine 再生
（MBAudioOutPort）、NSEvent → MBInputPort 写像（research R-2〜R-4）。

### MBTestReport（Tools: metalboy-testrom）

テスト ROM 1 本あたりの実行結果。

| フィールド | 型 |
|---|---|
| romPath | NSString |
| status | 合格 / 不合格 |
| message | NSString（CPU が出力した診断文字列。欠落可） |

## 関係のまとめ

- MBLaunchOptions --(romPath)--> MBCartridgeROM（1 起動に 1 ROM）
- MBCartridgeROM --(hasBattery)--> MBCartridgeRAM と MBSaveFile（復元/書出し）
- MBEmulatorState は MBCartridge / MBMemoryMap / MBPPU / MBApu を内包
- MBInputPort・MBRenderPort・MBAudioOutPort は機能層で定義され、UI 層が実装
