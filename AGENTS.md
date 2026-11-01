# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MetalBoy は Objective-C（ARC）製の Game Boy DMG エミュレーター（macOS 26+）。プロジェクト規約は `.specify/memory/constitution.md` が最上位。

## コマンド

Xcode プロジェクトは `MetalBoy/project.yml` から XcodeGen で生成する。ターゲットやファイルを追加したら `.xcodeproj` を直接編集せず再生成する。

```sh
cd MetalBoy
xcodegen generate
xcodebuild -project MetalBoy.xcodeproj -scheme MetalBoy -configuration Debug build
xcodebuild -project MetalBoy.xcodeproj -scheme MetalBoy -destination 'platform=macOS' test
# 単一テストクラス / メソッド
xcodebuild ... test -only-testing:MetalBoyTests/MBPPUTests
xcodebuild ... test -only-testing:MetalBoyTests/MBPPUTests/testXxx

# ヘッドレステスト ROM ランナー（シリアル出力を stdout へ、"Passed" で合格）
xcodebuild -project MetalBoy.xcodeproj -scheme metalboy-testrom build
metalboy-testrom /path/to/rom.gb --frames 1800 [--json]
# Mooneye 判定ツール（PASS/FAIL/TIMEOUT を出力）
xcodebuild -project MetalBoy.xcodeproj -scheme metalboy-mooneye build
metalboy-mooneye /path/to/rom.gb [--bios <path>] [--seconds N]

# アプリ本体
MetalBoy [--scale 1-8] [--volume 0-100] <rom-path>
```

テスト ROM（blargg / Mooneye）はリポジトリに同梱しない（`*.gb` は gitignore）。パスはユーザーに確認する。スイートと合格基準は `MetalBoy/Tests/TEST-ROMS.md` を参照。

## アーキテクチャ

3 層構成で、依存は `UI → Features → Core` の一方向のみ（詳細は `docs/architecture.md`）。

- **MetalBoyCore**（static lib, `Sources/Core`）：CPU / Memory / Cartridge / Video(PPU) / Audio(APU) / Joypad。Foundation 以外の OS 依存は禁止（ポータビリティ原則）
- **MetalBoyFeatures**（static lib, `Sources/Features`）：`MBEmulatorSession`、オプション解析、`.sav` 入出力、エラー→終了コード / 日本語メッセージ変換。UI との境界は `Ports/MBPorts.h` のプロトコル（Input / Render / AudioOut / Log）
- **MetalBoy**（app, `Sources/UI`）：AppKit + MetalKit + AVFAudio によるポート実装
- **metalboy-testrom**（`Sources/Tools/TestROM`）：`runFrames:` でヘッドレス駆動し、`serialOutputHandler` 経由でシリアル出力を収集する（blargg 用）
- **metalboy-mooneye**（`Sources/Tools/Mooneye`）：Core だけに依存する Mooneye 判定ツール

駆動モデル：`MBGameBoy` が `MBCPUBus` を実装する。`[cpu stepWithBus:]` は消費した M-cycle 数を返し、バスアクセスごとに `cpuTickCycle` で timer/serial、`ppu tickDots:4`、`apu tickDots:4` を進める（1 M-cycle = 4 dot）。PPU / CPU のタイミング修正はこのサイクル単位の進み方に依存する。

## 作業上の慣習

- TDD 必須。コア修正では `MetalBoy/Tests/MB*Tests.m` に回帰テストを先に追加する（CPU テストはモックバス `MBTestBus` を使う）
- 正確性の出典は Pan Docs 等の公開資料。実 ROM やテスト ROM の検証で見つかった修正・残課題は `docs/core-fidelity-notes.md` に追記する
- コミットメッセージは日本語で、`GameBoy: <変更要約>(Mooneye N/75)` の形式で現在の合格数を付ける
- ドキュメント・コメントは日本語、識別子は英語、クラス接頭辞は `MB`
- 機能追加は Spec Kit フロー（`/speckit-specify` → … → `/speckit-implement`）を使い、成果物は `specs/NNN-*/` に置く
