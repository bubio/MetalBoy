# Implementation Plan: CLI 起動型 GAME BOY エミュレーター（MetalBoy）

**Branch**: `001-gb-cli-emulator` | **Date**: 2026-10-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-gb-cli-emulator/spec.md`

## Summary

ROM ファイルを CLI 引数に指定して起動する DMG（初代 Game Boy）エミュレーター。
表示は Metal による専用ウィンドウ（スケール x1〜x8 既定 x3）、音声は AVAudioEngine
による出力（音量 0〜100% 既定 50%）、キーは固定割り当て（矢印=D-Pad、Z=B、X=A、
Enter=Start、スペース=Select）。オプションの永続化はせず、カートリッジのセーブ
データのみ ROM と同じ場所にセーブファイルとして保存・復元する。BIOS なし起動。
技術アプローチ: Objective-C（モダン記法 / ARC）× Xcode プロジェクトで
エミュレーションコア層・機能層・UI 層を分離したマルチターゲット構成（憲法 v2.0.0）。

## Technical Context

**Language/Version**: Objective-C（最新のモダン記法、ARC 必須）。開発言語は
  唯一これとし、補助ツール・テストランナーも Objective-C 製（憲法原則 I）。

**Primary Dependencies**:
- AppKit（NSWindow / NSApplication / キー入力）— UI 層のみ
- Metal / MetalKit（MTKView へのフレームバッファ描画・整数倍拡大）— UI 層のみ
- AVFoundation / AVAudioEngine（音声出力）— UI 層のみ
- XCTest（ユニット/統合テスト）
- 外部ライブラリの追加はしない（SDL は macOS では使わない。原則 VI の
  ポータビリティ確保のためコア・機能層はOS 非依存の生 Objective-C のみ）

**Storage**: ファイルシステムのみ。セーブ対応カートリッジのセーブ領域を
  `<ROM ファイル名>.sav`（ROM と同じディレクトリ）に書き出し/読み込み。
  オプション・設定の永続化はしない（仕様 FR-006）。

**Testing**: XCTest（コア層・機能層のユニットテスト／機能層経由の統合テスト）
  + 公開テスト ROM（blargg 系スイート等）を実行する Objective-C 製テストランナー
  （SC-007 の受け入れ判定）。

**Target Platform**: macOS 26.0 以降（Apple Silicon / Intel 両対応の想定）。
  UI 層は macOS 専用 API をここに閉じて、他 OS・SDL を使うフロントエンドを
  将来容易に追加できる構成（憲法原則 VI）。

**Project Type**: デスクトップ GUI アプリ（ウィンドウはエミュ表示のみ）+
  コア・機能層のライブラリターゲット。CLI から起動し、オプションは起動引数
  のみで指定する。

**Performance Goals**: 起動からゲーム画面表示まで 2 秒以内（SC-001）。
  キー操作から画面反応まで体感遅延 100ms 以内（SC-002）。DMG の約 59.727 fps
  を実時間で維持（入力遅延要件の根拠）。

**Constraints**:
- オプション範囲外は既定値へフォールバックせず必ずエラーで失敗（FR-005）
- BIOS 不在の起動時初期化のみでエミュレーション開始（FR-007）
- キー割り当ての変更機能なし（FR-008）、ポーズ機能なし（FR-015）
- ネットワーク依存なし（憲法技術要件）
- ドキュメント・コミット・レビューは日本語、コード識別子は英語（憲法）

**Scale/Scope**: 単一機能（フィーチャー 001）で完結する最小構成。
  3 層 3 ターゲット（コア / 機能 / UI）+ テストターゲット。

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 憲法原則 | 状態 | 根拠 |
|---|---|---|
| I. Objective-C 一元化 | 合格 | 全ターゲットを Objective-C（モダン記法、ARC）で実装。テストランナーも Objective-C 製 |
| II. ライブラリー・ファースト（層分離） | 合格 | エミュレーションコア層 / 機能層 / UI 層を Xcode のターゲットとして分離。上位からの依存のみ、UI 依存を UI 層に閉じる |
| III. 仕様準拠と正確性 | 合格 | DMG 準拠、Pan Docs 等を出典に実装。テスト ROM 合格（SC-007）を品質ゲート化 |
| IV. テスト・ファースト | 合格 | XCTest + テスト ROM ランナーを tasks の必須要素に組み込む |
| V. シンプルさと可観測性 | 合格（注記） | GUI はエミュ表示のみのため対話的デバッガ CLI は持たない代わりに、起動引数・stderr のエラー出力とログを可観測手段とする。デバッグ用の詳細ログ出力オプションは付加しない（FR-006 境界を尊重し、tasks 実装時に過剰化しないよう注意） |
| VI. ポータビリティ | 合格 | コア層・機能層は Foundation のみに依存（AppKit/Metal/AVFoundation なし）。描画・入力・音声はプロトコル抽象（機能層で定義）を UI 層が実装 |

**判定**: 違反なし。複雑性の追加は層分離（憲法要求）とスコープ（001 フィーチャー）の
必要最小限に留まる。

## Project Structure

### Documentation (this feature)

```text
specs/001-gb-cli-emulator/
├── plan.md              # 本ファイル
├── research.md          # Phase 0 成果物
├── data-model.md        # Phase 1 成果物
├── quickstart.md        # Phase 1 成果物
├── contracts/           # Phase 1 成果物（CLI 契約・層間契約）
└── tasks.md             # Phase 2 成果物（/speckit.tasks で作成）
```

### Source Code (repository root)

```text
MetalBoy/                      # リポジトリ/フォルダ名は SwiftGB のまま（憲法技術要件の例外）
├── MetalBoy.xcodeproj         # Xcode プロジェクト（マルチターゲット）
├── Sources/
│   ├── Core/                  # エミュレーションコア層（ターゲット: MetalBoyCore）
│   │   ├── CPU/               # CPU 命令実装（タイマ・割り込みを含む）
│   │   ├── Memory/            # バス・メモリマップ・DMG 初期化（BIOS なし起動相当）
│   │   ├── Video/             # PPU（フレームバッファ生成のみ。描画はしない）
│   │   ├── Audio/             # APU（PCM サンプル生成のみ。再生はしない）
│   │   ├── Cartridge/         # ROM ヘッダ解析・MBC0/1/2/3/5・セーブ領域
│   │   └── Joypad/            # 十字キー/A/B/Start/Select の入力レジスタ
│   ├── Features/              # 機能層（ターゲット: MetalBoyFeatures）
│   │   ├── Emulation/         # 実行ループ・フレーム駆動・状態管理
│   │   ├── Save/              # セーブファイル読み書き（.sav）
│   │   └── Ports/             # UI との抽象ポート（描画/入力/音声のプロトコル）
│   ├── UI/                    # UI 層（ターゲット: MetalBoy。AppKit 固有）
│   │   ├── App/               # main / 起動引数解析は機能層経由で
│   │   ├── Window/            # NSWindow / MTKView（エミュ表示）
│   │   ├── Audio/             # AVAudioEngine 出力
│   └── Tools/                 # テスト ROM ランナー（ターゲット: metalboy-testrom、CLI）
└── Tests/                     # XCTest（Core / Features / UI 向け）
```

**Structure Decision**: マルチターゲット Xcode プロジェクトを採用。
`MetalBoyCore`（OS 非依存コア）→ `MetalBoyFeatures`（Foundation のみ・ポート抽象）
→ `MetalBoy`（UI 層、AppKit/Metal/AVFoundation）の依存方向をコンパイラで強制する。
テスト ROM ランナーはアプリ化しない軽量 CLI ターゲットとする。

## Complexity Tracking

> 憲法チェックに違反がないため、記載なし。
