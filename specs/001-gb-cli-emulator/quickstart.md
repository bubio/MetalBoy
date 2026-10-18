# Quickstart: 検証・実行ガイド

**Branch**: `001-gb-cli-emulator` | **Date**: 2026-10-18

機能仕様の Success Criteria（SC-001〜SC-007）を実際に確認するための手順。
実装コードやテストコードの中身はここに書かない（tasks.md / 実装フェーズ参照）。

## 前提条件

- macOS 26.0 以降の Mac
- Xcode（macOS 26 SDK / Metal / AVFoundation 利用可能な版）
- 検証用 Game Boy ROM ファイル（ユーザー自身が用意。本リポジトリは
  ROM を同梱・配布しない）
- 検証用テスト ROM（blargg 等の公開スイート。入手はユーザー側で行う）

## ビルド

```sh
xcodebuild -project MetalBoy/MetalBoy.xcodeproj \
  -scheme MetalBoy -configuration Release build
```

ビルド済みアプリは `MetalBoy.app`（名称は MetalBoy。機種依存の DerivedData
出力先から取得）。テスト ROM ランナーは別ターゲット
`metalboy-testrom`（CLI 実行バイナリ）。

## 実行

```sh
# 既定（スケール x3、音量 50%）で起動
MetalBoy /path/to/game.gb

# オプション指定で起動
MetalBoy --scale 8 --volume 100 /path/to/game.gb
```

起動するとゲーム画面専用のウィンドウが表示される。キー割り当ては
矢印=十字キー、Z=B、X=A、Enter=Start、スペース=Select（固定）。

## 検証シナリオ（Success Criteria 対応表）

### SC-001: 起動が 2 秒以内で画面表示（US1）

```sh
time MetalBoy /path/to/game.gb
```

- 期待: コマンド実行から 2 秒以内にゲーム画面がウィンドウへ表示される

### SC-002: 入力遅延 100ms 以内

- ゲーム内でキャラクターを移動させ、キー押下から画面反応までの体感遅延を確認
- 期待: 目視で気になる遅延がない（100ms 以内）

### SC-003: スケール x1〜x8 全件確認

```sh
for s in 1 2 3 4 5 6 7 8; do MetalBoy --scale $s /path/to/game.gb; done
```

- 期待: 各起動のウィンドウに、指定倍率の等比拡大でゲーム画面が表示される
- 無指定時: x3 で表示される

### SC-004: 音量 0% / 50% / 100% の変化

```sh
MetalBoy --volume 0   /path/to/the-sound-test.gb   # 完全無音
MetalBoy --volume 50  /path/to/the-sound-test.gb
MetalBoy --volume 100 /path/to/the-sound-test.gb
```

- 期待: 0% は無音。50% → 100% の順に大きくなる
- 無指定時: 50%

### SC-005 / US3: エラーとクリーンな失敗

```sh
MetalBoy                                     # → 用法表示（終了コード 2）
MetalBoy --scale 9           /path/gb        # → 範囲外エラー（2）
MetalBoy --volume 300        /path/gb        # → 範囲外エラー（2）
MetalBoy /path/not-exists.gb                 # → 不在エラー（1）
MetalBoy /path/not-a-rom.txt                 # → 無効 ROM エラー（1）
MetalBoy /path/cgb-only.gbc                  # → CGB 専用非対応エラー（1）
MetalBoy /path/unsupported-mapper.gb         # → 非対応マッパーエラー（1）
```

- 期待: いずれも 1 秒以内に stderr へ 1 行の日本語エラーを出して終了
- 期待: どこにも既定値へのフォールバックが発生しない

### SC-006: 初心者が 5 分以内に起動・基本操作できる

- ヘルプ（上記、ROM 未指定時の用法表示）とエラーメッセージのみを頼りに
  ここまでの起動・操作が完了すること

### US2/FR-013 連動: セーブデータの永続化

```sh
# 1) セーブ対応 ROM を起動し、ゲーム内でセーブしてウィンドウを閉じる
MetalBoy /path/to/game.gb
# → <game.sav が /path/to/ に作成される>

# 2) 再度起動
MetalBoy /path/to/game.gb
- 期待: 前回セーブした進行状態から再開される
- セーブ非対応 ROM では .sav が作られないこと
```

### SC-007: テスト ROM の合格

```sh
metalboy-testrom /path/to/blargg/cpu_instrs/cpu_instrs.gb
# → 合格/不合格と診断文字列を報告する
```

- 期待: tasks.md で確定する使用スイート一覧が全項目合格
```
