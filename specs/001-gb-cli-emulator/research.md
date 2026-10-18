# Phase 0 Research: CLI 起動型 GAME BOY エミュレーター（MetalBoy）

**Branch**: `001-gb-cli-emulator` | **Date**: 2026-10-18

各決定は憲法 v2.0.0（Objective-C 一元化 / 層分離 / ポータビリティ / DMG 準拠）
と機能仕様（spec.md の FR・SC）に整合させる。

## R-1: 実装言語とビルド構成

- **Decision**: Objective-C（モダン記法、ARC 必須）で全ターゲットを実装し、
  Xcode プロジェクト（マルチターゲット）で管理する。
- **Rationale**: 憲法原則 I（Objective-C 一元化）と macOS 26.0 以降対象の
  指定に従う。層の依存方向（Core → Features → UI）をターゲット依存で
  ビルド時に強制できる。
- **Alternatives considered**:
  - SwiftPM パッケージ内に Objective-C ターゲットを置く構成: GUI アプリ
    ターゲット（Info.plist、バンドル、エンタイトルメント）の管理が冗長に
    なるため不採用。
  - CMake 等でのビルド: macOS 26 の SDK 機能（Metal、AppKit）への追随が
    手動になるため不採用。

## R-2: 画面描画方式（UI 層）

- **Decision**: Metal（MTKView）でエミュのフレームバッファ（160×144 RGBA）を
  テクスチャとして描画し、整数倍（x1〜x8）のスケールをビューポートで反映する。
  アプリ名は MetalBoy であり、macOS 26+ の標準的 GPU 経路に一致する。
- **Rationale**: 仕様は描画方式を規定していないが、整数倍拡大はスケール値を
  そのままピクセル等比に写像でき、SC-003（全スケール値の検証可能性）に直結。
  nearest フィルタでピクセル感を保つ。
- **Alternatives considered**:
  - NSImageView + Core Image での拡大: 60fps 連続更新・低遅延ではメモリ
    コピーが増え、入力遅延 SC-002 の余裕が減るため不採用。
  - SDL を macOS でも使う: 憲法 VI は「使うこと」ではなく「接続しやすさ」を
    要求するのみ。macOS ではシステム標準の Metal が最短経路のため不採用
    （SDL 対応は将来のフロントエンド追加時に Ports 契約を実装して達成）。

## R-3: 音声出力方式（UI 層）

- **Decision**: AVAudioEngine のソース ノードへ、APU が生成した PCM サンプルを
  リングバッファ経由で供給する。音量（0〜100%）は UI 層側の出力ゲインとして
  適用する（コアの APU は音量を知らない）。
- **Rationale**: DMG 準拠（原則 III）を保つには、APU は PCM 生成のみに専念し、
  音量のようなホスト側の再生条件は UI 層に属させるのが層分離に整合。
  音量 0% はゲイン 0 で完全無音（SC-004）。
- **Alternatives considered**:
  - APU 内部で音量を掛ける: コアが UI の状態（音量）を知ることになり
    層分離違反となるため不採用。
  - AudioUnit 直叩き: AVAudioEngine で十分かつ保守が軽いため不採用。

## R-4: キー入力（UI 層）と抽象ポート

- **Decision**: 機能層に `MBInputPort`（ボタン状態のセット/クリア）を定義し、
  UI 層のキーイベント（矢印 / Z / X / Enter / スペース、キーコードは
  `NSEvent` から取得）がポートへ写像する。割り当て表は UI 層の固定定数とする。
  修飾キー（Shift/Command 等）の併用による入力変化は扱わない。
- **Rationale**: FR-008 の固定割り当てを満たしつつ、キーイベントの取得を
  AppKit 依存として UI 層に閉じる（原則 VI）。
- **Alternatives considered**: HID 直参照（IOKit）: ポータビリティを損なう
  ため不採用。

## R-5: BIOS なし起動の初期化

- **Decision**: DMG の電源投入相当のレジスタ初期値（AF/BC/DE/HL、SP、各種
  I/O レジスタ、BG パレットの DMG 既定値）を直接設定し、`$0100` から実行を
  開始する。BIOS イメージの読み込み・`$0000–00FF` の実行再現は実装しない。
- **Rationale**: FR-007（BIOS 不要・BIOS 読み込み手段なし）。Pan Docs /
  GBATEK の DMG 起動直後レジスタ値を出典として使用。
- **Alternatives considered**: CGB ブート相当の分岐も cgb フラグ検出も
  実装しない（DMG のみ・FR-012）。

## R-6: カートリッジ対応（MBC）とセーブデータ

- **Decision**: MBC0 / MBC1 / MBC2 / MBC3 / MBC5 をサポート。ROM ヘッダ
  `$0147` のカートリッジタイプから MBC 種別を判定し、範囲外タイプは
  非対応エラーとして起動失敗（FR-016 / FR-011）。MBC3 の RTC は簡易対応
  （実時間をソースとするレジスタ実装）とし、厳密な RTC 振る舞いの
  検証はテスト ROM の合格基準から外さない範囲で最小限にする。
- **Rationale**: 市販 DMG タイトルの大多数をカバーする最小の実装集合。
  セーブ対応タイプ（SRAM を持つタイプ）のみ `.sav` を扱う（FR-013 / FR-014）。
- **Alternatives considered**:
  - MBC7 / MMM01 などの各タイプへの対応: スコープ外（FR-016 の範囲外エラーに従う）。
  - RTC の完全実装（セーブへの経過時刻記録）: 厳密性の優先度が低く、
    テスト ROM 合格に寄与しないため本フィーチャーでは簡易とする。

## R-7: セーブファイル仕様

- **Decision**: パスは ROM ファイルと同じディレクトリの
  `<ROM ベース名>.sav`。内容はカートリッジ SRAM の生バイト列（MBC2 の場合は
  アドレス当たり上位 4bit を無視した実データの生列）。起動時に存在すれば
  読み込み、サイズが SRAM サイズと一致しない・読めない場合はエラーで
  失敗する（黙って上書きしない）。終了時（正常終了・Ctrl+C 含む）に書き出す。
- **Rationale**: FR-013 の「ROM と同じ場所・自動復元」。破損時に黙って
  上書きしない方針は仕様 Edge Cases に合致し、実装も単純（生ダンプ）。
- **Alternatives considered**:
  - 破損時に無視して空 SRAM で起動: 仕様の Edge Cases では「いずれか」を
    許容しているが、ユーザーデータ消失の誤解を避けるためエラーを既定とする。
  - JSON/独自コンテナでメタデータ付き保存: 標準的な `.sav` 生ダンプの方が
    他エミュレータとの互換性が高いため不採用。

## R-8: CLI 引数契約

- **Decision**: `MetalBoy [--scale N] [--volume P] <rom-path>` を契約とする
  （詳細は contracts/cli.md）。機能層の `MBOptionParser` が引数を解析し、
  範囲外は許容範囲を示すメッセージとともに失敗する（FR-005）。
- **Rationale**: 仕様の 2 オプション（スケール/音量）に最小で対応。
  ヘルプ出力は使い方を stderr に 1 度表示するだけ（FR-011 / SC-006）。
- **Alternatives considered**: 設定ファイルや環境変数: 永続化禁止（FR-006）
  に反するため不採用。

## R-9: テスト ROM の受け入れ実行

- **Decision**: blargg 系の CPU/PPU/APU 検証 ROM を対象に、コア層を直接
  呼び出す軽量 CLI ランナー（metalboy-testrom）を Objective-C で用意する。
  ROM 実行結果（CPU が標準出力ポートへ書いた文字列 / 成否コード）を収集し、
  合格/不合格を報告する。使用スイートの具体的なリストは tasks.md で確定する。
- **Rationale**: SC-007をゲート化するための最小構成（UI 依存なし）。
- **Alternatives considered**: XCTest 内に埋め込む: ROM バイナリの同梱の扱い
  （著作権・サイズ）をシンプルにするため、ランナーは ROM パスを引数で
  受け取る CLI とし、XCTest からも呼び出せる形にする。

## R-10: 観測性（ログ）

- **Decision**: stderr への起動エラー出力（FR-011）と、コア層の未実装・
  未確定挙動を捕捉する内部ログフック（機能層の `MBLogPort`）を最小構成で
  用意する。既定では通常動作に影響しない最小限の出力のみ。
- **Rationale**: 憲法 V（可観測性）と FR-006/スコープ最小化の両立。
- **Alternatives considered**: 詳細なデバッグ CLI（レジスタダンプ等）の
  同梱: 本フィーチャーのスコープ外（将来フィーチャーとして追加可能）。
