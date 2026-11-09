# MetalBoy

macOS 26 対応の GAME BOY(DMG) エミュレーター。Objective-C + Metal 製。

## 概要

MetalBoy は初代 GAME BOY(DMG) のゲームを遊べる CLI 起動型のエミュレーターです。
ターミナルから ROM ファイルを指定して起動すると、ゲーム画面のウィンドウと音声だけで遊べます。
エミュ表示以外の GUI(メニュー・設定画面など)を持たず、オプションも設定ファイルも使いません。

- 対応カートリッジ: MBC0 / MBC1 / MBC2 / MBC3(+RTC 簡易) / MBC5
- CGB(GAME BOY Color) 専用 ROM は非対応(起動時にエラー終了)
- BIOS(ブート ROM) は不要です
- テスト ROM(blargg / Mooneye) でエミュレーション精度を検証しています

## 動作条件

| 項目 | 内容 |
|---|---|
| OS | macOS 26 以降 |
| サウンド | Metal 対応 Mac |

## 使い方

### 起動

ターミナルから ROM ファイルを指定して起動します。

```sh
/path/to/MetalBoy.app/Contents/MacOS/MetalBoy path/to/game.gb
```

オプション:

```
Usage: MetalBoy [--scale 1-8] [--volume 0-100] <rom-path>

  <rom-path>    GAME BOY ROM ファイルのパス(必須)
  --scale N     画面スケール。整数 1〜8(既定 3)
  --volume P    音量。整数 0〜100(既定 50)
```

オプションを省略した場合は既定値(スケール x3・音量 50%)で起動します。
範囲外の値を指定した場合、既定値へフォールバックせず許容範囲を示すエラーで即座に失敗します。

### キー操作

| キー | ボタン |
|---|---|
| 矢印キー | 十字キー(↑↓←→) |
| Z | B |
| X | A |
| Enter | Start |
| スペース | Select |
| Cmd+Q / ウィンドウを閉じる | 終了 |

ゲーム進行以外のランタイム操作(ポーズ等)はありません。終了操作のみです。

### セーブデータ

電池バックアップ対応のカートリッジでは、ROM と同じ場所に
`<ROM ベース名>.sav`(SRAM の生ダンプ)が作成されます。

- 起動時に自動的に復元し、終了時に書き出します
- 既存の `.sav` のサイズ不一致や読み取り不能な場合は、黙って上書きせず
  **起動に失敗**します(セーブデータを壊しません)

## ソースからビルド

[Xcode](https://developer.apple.com/xcode/) と [XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。

### 手順

```sh
cd MetalBoy
xcodegen generate       # project.yml から MetalBoy.xcodeproj を生成
xcodebuild -project MetalBoy.xcodeproj -scheme MetalBoy -configuration Debug build
```

### テスト

回帰テストは `MetalBoy/Tests/` にあります。

```sh
xcodebuild -project MetalBoy.xcodeproj -scheme MetalBoy -destination 'platform=macOS' test
# 単一クラスなら -only-testing:MetalBoyTests/MBPPUTests のように絞り込めます
```

テスト ROM(リポジトリには同梱されません)を用いて精度を検査するための
ヘッドレスツールも付属しています(macOS 向けビルド手順):

- `metalboy-testrom`: blargg 系テスト ROM を `runFrames:` で駆動し、シリアル出力を stdout へ出力
- `metalboy-mooneye`: Mooneye 系テスト ROM の判定ツール(PASS / FAIL / TIMEOUT)

スイート一覧と合格基準は [`MetalBoy/Tests/TEST-ROMS.md`](MetalBoy/Tests/TEST-ROMS.md) を参照してください。

## アーキテクチャ

`UI → Features → Core` の一方向依存による 3 層構成です:

| レイヤー | 内容 |
|---|---|
| **MetalBoyCore** (static lib) | CPU / Memory / Cartridge / PPU / APU / Joypad。OS 依存を排除したポータブルな純粋コア |
| **MetalBoyFeatures** (static lib) | `MBEmulatorSession`、オプション解析、`.sav` 入出力、エラー変換。UI との境界はプロトコル(`Ports/MBPorts.h`) |
| **MetalBoy** (app) | AppKit + MetalKit + AVFAudio によるポート実装 |

ドキュメント:

- [`docs/architecture.md`](docs/architecture.md) — アーキテクチャとポート契約の詳細
- [`docs/core-fidelity-notes.md`](docs/core-fidelity-notes.md) — 精度検証で判明した実装メモ
- [`specs/`](specs/) — Spec Kit の仕様・設計ドキュメント

## License

[MIT](LICENSE) ライセンスで公開予定です(LICENSE ファイルは準備中)。
