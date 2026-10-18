# Contracts: CLI 起動型 GAME BOY エミュレーター（MetalBoy）

**Branch**: `001-gb-cli-emulator` | **Date**: 2026-10-18

外部に見える契約は 2 種類: (1) ユーザーへの CLI 契約、(2) 内部レイヤ間の
ポート契約（ポータビリティの接点）。記法は擬似 Objective-C
メソッドシグネチャとし、実装型の全詳細（ヘッダの説明など）は tasks.md 以降の
実装段階で確定する。

## 1. CLI 契約（ユーザー向け）

### 用法

```text
MetalBoy [--scale N] [--volume P] <rom-path>

  <rom-path>    Game Boy ROM ファイルのパス（必須、位置引数 1 個のみ）
  --scale N     画面スケール。整数 1〜8（既定 3）
  --volume P    音量。整数 0〜100（パーセント記号なし、既定 50）
```

### 契約ルール

- 上記以外のオプション・複数の位置引数は未対応: 使い方表示 + 終了コード 2
- ROM 未指定・範囲外オプション: 許容範囲を示すエラー（stderr）+ 終了コード 2
- ROM 不在・無効 ROM・非対応マッパー・CGB 専用 ROM:
  原因を示すエラー（stderr）+ 終了コード 1
- 正常起動 → クリーン終了: 終了コード 0。stdout には通常何も書かない
- すべてのエラーメッセージは日本語で原因を 1 行で説明する（FR-011）
- オプション値への既定値フォールバックは存在しない（FR-005）

### 終了コード定義

| コード | 意味 |
|---|---|
| 0 | 正常終了（ゲーム内から / ウィンドウを閉じる / Ctrl+C） |
| 1 | ランタイムエラー（ROM 不在・無効・非対応・セーブ読書き失敗等） |
| 2 | 引数解析エラー（使い方を示す） |

### Ctrl+C 挙動

SIGINT 受信時はウィンドウを閉じる場合と同等のクリーン終了経路を通る
（セーブデータ書出し → リソース解放 → 終了コード 0）。

## 2. レイヤ間ポート契約（内部）

依存方向: UI → Features → Core（Core は Features すら知らない）。

### Features → UI が実装するポート

```objc
@protocol MBInputPort <NSObject>
- (void)setButton:(MBButton)button pressed:(BOOL)pressed;
@end
// MBButton: up/down/left/right/a/b/start/select

@protocol MBRenderPort <NSObject>
// コアが生成した 160x144 RGBA8 フレームの供給受付（UI が拡大して描画）
- (void)presentFramebuffer:(const uint32_t *)pixels;
@end

@protocol MBAudioOutPort <NSObject>
// コアが生成した PCM サンプルの供給受付（音量適用とキュー管理は UI 側）
- (void)enqueueSamples:(const int16_t *)samples count:(NSUInteger)count;
@end

@protocol MBLogPort <NSObject>
- (void)logEvent:(MBLogEvent)event message:(NSString *)message; // 未実装挙動の記録
@end
```

### UI → Features が提供する振る舞い

```objc
@interface MBEmulatorSession : NSObject
- (nullable instancetype)initWithOptions:(MBLaunchOptions *)options
                                   error:(NSError **)error;
// 起動: ROM 解析 → BIOS なし初期化 → セーブ復元（FR-013）
// 解析・検証エラーは NSError（内包する情報は FR-011 の原因分類に対応）

@property (nonatomic, readonly) id <MBRenderPort> renderPort;
@property (nonatomic, readonly) id <MBAudioOutPort> audioOutPort;
@property (nonatomic, readonly) id <MBInputPort> inputPort;

- (void)run;     // 実時間（約 59.727 fps）でエミュレーションを駆動
- (void)stop;    // クリーン停止: セーブ書出し → リソース解放（FR-010）
@end

@interface MBOptionParser : NSObject
+ (nullable MBLaunchOptions *)parseArguments:(NSArray<NSString *> *)args
                                       error:(NSError **)error;
@end

@interface MBSaveFile : NSObject
- (nullable NSData *)loadWithError:(NSError **)error; // 無ければ nil（エラーなし）
- (BOOL)saveData:(NSData *)data error:(NSError **)error;
@end
```

### Core が Features に提供する最小 API

```objc
@interface MBCartridge : NSObject
- (nullable instancetype)initWithROMData:(NSData *)rom error:(NSError **)error;
@property (nonatomic, readonly) MBCartridgeType cartridgeType;
@property (nonatomic, readonly) BOOL hasBattery;
@property (nonatomic, readonly) NSUInteger ramSize;
@property (nonatomic, readonly) NSData *currentRAM;   // 終了時の書出し元
- (void)restoreRAM:(NSData *)ram;
@end

// MBEmulator / MBPPU / MBApu はコア内での利用が主。Features へは
// フレーム・PCM・Joypad 入力の受け渡しで十分とする（tasks で確定）。
```

### Core の制約（ポータビリティ原則 VI / II）

- Foundation（NSData/NSString 等）は可。AppKit / Metal / AVFoundation は
  コンパイル単位から存在してはならない
- 描画・音声再生・キー入力の OS 固有コードを含まない（テスト可能な純粋状態機械）
