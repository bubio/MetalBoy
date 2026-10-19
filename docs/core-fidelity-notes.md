# コア精密度メモ — 実 ROM 検証で起きた修正と残課題

日付: 2026-10-18
対象: MetalBoy(GB DMG コア有限目標物)

## 発見した重大バグ(修正済)

### 1. CB プレフィックス命令の x デコードが全体的に1つずれ(`MBCPU.m`)
SM83 の CB 命令は `ccc yy rrr` 構造で:

| x(ccc) | 正しい命令群 | 修正前の実装 |
|---|---|---|
| 0 ($00-$3F) | RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL | RLC-RRC-RL-RR のみ(y≥4 が誤って RR 動作) |
| 1 ($40-$7F) | BIT y,r | SLA/SRA/SWAP/SRL として実行されていた |
| 2 ($80-$BF) | RES y,r | BIT y,r として実行されていた |
| 3 ($C0-$FF) | SET y,r | RES y,r として実行されていた |

→ BIT を多用する実 ROM ではフラグが崩れ、STAT 待ちループが永久停止。
**Prince of Persia の起動で確認**(STAT bit1 の BIT 1,A が SLA として動いていた)。
回帰テスト: `MBCPUTests testCBBit*` / `testCBSwapWorks` / `testCBResAndSet`。

### 2. IME=0 での HALT が永久に解除されない(`MBCPU.m` + `MBCPU.h` + `MBGameBoy.m`)
Pan Docs 仕様: **(IF & IE) != 0 なら IME と無関係に HALT を解除**(IME=0 的場合は直後命令を実行)。
修正前は `_ime && ifReg` のときだけ解除 → Pokémon(IE=0x0C で halt 待ち)が永久に動かない。
バスプロトコルに `ieRegister` を追加。

### 3. $FF26(NR52 音源電源)の読取り値が不正(`MBApu.m`)
default パスで 0xFF を返していたが、実機 DMG は bit4-6=1・bit0-3=0(= 0xF0 powered / 0x70 off)。
blargg 系テストは `LDH A,(FF26); AND 1; JR NZ` で待つため bit0=1 では無限ループ。

### 4. シリアル送受の受信側が未実装(`MBMemoryMap.m`)
実機は外部機器なしでも送信時に `$FF01` に `$FF`(未接続の Idle 値)が取り込まれる。
修正前は受信 AND なし → SGB 風パケット検出や blargg コンソールの連続再送と衝突。

## 検証結果

| ROM | 結果 |
|---|---|
| Prince of Persia (Japan).gb | ✅ タイトル → 「CONTINUE / NEW GAME」メニュー到達 |
| Tetris (Japan) (En).gb | ❌ 白画面(LCDC bit7=0 で止まる・VRAM 展開は進行) |
| Pocket Monsters 赤 (Japan).gb | ❌ 黒画面($FF8A の STOP/HALT で SGB 関係の待ち) |
| blargg cpu_instrs individual | ❌ バナー出力後に再送ループ(さらに精密化が必要) |
| blargg 自作 serial ミニ ROM | ✅ "Pass" |
| XCTests | 51/51 パス |

## 残課題(次のセッション)

1. **Mooneyeテストスイート**(Gekkio)の採用: シリアル非依存で成功/失敗判定が可能。
   - `Gekkio/mooneye-test-suite` release の prebuilt ROM を wget して使用 가능。
   - 特に `hardware/oam_dma`、`ppu/vblank_*`、`timer/*` が現在の弱点を狙撃する。
2. **実 BIOS の optional サポート**:`[BIOS] Nintendo Game Boy Boot ROM (Japan) (En).gb` を
   オプション引数で読(string)、ロゴ落下アニメ + header checksum 検証が通るか確認する。
   - BIOS 不要要件は崩さない(`--bios` が指定されたときだけ読み込む)。
3. **OAM DMA ($FF46) の精密化**: 現在は同期即時転送。実機は 160 M-cycle かけて
   徐々に転送するため、OAM 中間状態や CPU-OAM のNullisationsの検証が不完全。
4. **STOP 命令(SGB パケット)**: Pokemon が STOP を多用。現状は halt 相当の簡略。
   SGB パケット送信プロトコルを検討(P1 行選択と STOP を使う方式)。
5. DIV カウンタ上位 8bit: `FF04` 読取りは `_divCounter >> 8` で実装済。
6. blargg テストの再送ループの残因: `$FF02` の読み出しエコー(bit7)、転送
   完了タイミング(8 M-cycle)、serial IF 立上げの配列をさらに詰める。

## デバッグに使用した道具(全て /tmp。本番ビルドに含まれない)

- `/tmp/MBCPU_trace.m` — MBCPU に atexit の PC ヒストグラム/直近 4096 命令 tail
  (pc/haltes/AFBCDEHLSP/opcode 3byte)を記録するデバッグコピー。
  使い方: `MB_TRACE_OUT=hot.txt MB_STREAM_OUT=tail.txt <bin>`
  libTrace: `cp libMetalBoyCore.a /tmp/libCoreTrace.a && ar d /tmp/libCoreTrace.a MBCPU.o`
- `/tmp/mbrunfb.m` — runFrame 数回したあとの pc/IF/IE/HRAM/WRAM/PPU レジスタ表示。
- `/tmp/mbserv.m` — serialWrite(PC 付き)/serial バイト収集を ASCII 連続列で表示。
- `/tmp/mbkeys.m` — フレーム指定のボタン入力シミュレーション + PPM ダンプ。
- `/tmp/mbtimer.m` / `/tmp/mbhram.m` — タイマ・HRAM 単体確認。

# 2026-10-19: 実 ROM(実 BIOS 付き)停滞の第2〜4根本原因修正

Tetris(実 BIOS 駆動)の停滞をpc 系ヒストグラム/待機ループの LY 読み取り値プローブで切り分け、
以下を修正した(XCTests 59/59 パス)。

## 1. `$E9`(JP (HL)) / `$E8`(ADD SP,e8) がスイッチ case から抜けていた(→ NOP 扱い)

- Tetris の RST28 ディスパッチャ(`$0028: 87 e1 5f 16 00 19 5e 23 56 d5 e1` **`e9`**)
  の最終命令 `JP (HL)` が NOP 扱いで `$0034`(`$FF`=RST $38)へ落ち、RST $38 トラップ無限ループに
  なっていた。histogram 上 `$0038 ×3909回/600F` の正体。
- `$E8`(ADD SP,e8) も同時欠落。Tetris など実 ROM のスタック整合宣言で使用される。
- 回帰テスト: `testJPHl` / `testAddSpSigned`(MBCPUCallRetTests.m)。
- 教訓: オペコード実装網羅性のチェックは case 列挙だけでは不十分($40-$BF は汎用デコードで
  処理され case に現れない)。正しい判定には `0x00-0xFF` の全 case 洗い出し + 汎用パスの範囲
  確認を組み合わせる。

## 2. BIOS ウィンドウに CGB ルールを誤用(`$0200-$08FF` も BIOS 可視扱い)

- `cpuReadFromBootROM:` が `$0000-$00FF` に加え `$0200-$08FF` を返していた。これは **CGB ブート
  ROM**(512B を $0000-$00FF と $0200-$08FF に分割配置)のルールで、DMG の 256B ブート ROM では
  存在しない窓。Tetris が割込み volteで $0200 以降の命令を BIOS の `$FF` タイルからフェッチし、
  ISR の push 列(HL=$97FF 二重 push)で暴走していた。
- 対応: DMG 専用のため `address < 0x0100` のみ。回帰テスト: `testBootROMWindowIsDMGOnly`
  (MBBootROMWindowTests.m)。

## 3. 割込みディスパッチが IE をマスクしていなかった(実 ROM 停滞の直接トリガ)

- `if (_ime && ifReg != 0)` で判定しており、IE=08(Timer のみ)で VBlank 以外の許可がない状態でも
  VBlank ISR が毎フレーム発火(実測: 600F 中 2056 回の誤 dispatch)していた。
- Tetris は LY=$91 ポーリング(`$287C: LD A,(FF44); CP $91; JR NZ`)で LCD OFF 前の同期を取るが、
  誤発火 ISR 実行中の ~2280 dots の間 LY 読み取りができず、毎フレーム **LY=$8F→$95 の 5 ライン
  スキップ**が生じ CP $91 が永遠に成立しなかった(待機ループ内 $90-$94 の読み取り 0 回)。
- 対応: `serviceable = ifReg & ieRegister & 0x1F` でマスク。HALT 唤醒部と同一条件に統一。
- 回帰テスト: `testInterruptRequiresIEEntry`(IE に許可されていない IF ビットでは発火しない/発効
  が検証できる)。

## 4. 割込み受け付けの 20 T-cycle がバスに供給されていなかった

- ディスパッチの早期 `return 5` が `tickBusTimes` を通らず PPU/APU/timer が 20 dots 進んでいな
  かった。`tickBusTimes:count:5` を呼ぶよう修正。

## 修正後の実 ROM 状態(実 BIOS + 600 フレーム、PPM→PNG 目視)

※ 注意: この時点ではまだ 4 倍速バグ(後述 #5)が未発見で、600F の観測は実時間の 2400F 相当。
   実時間レートでの再検証は「追記(2026-10-19)」の表を参照。

| ROM | 修正前 | 修正後 |
|---|---|---|
| Tetris (Japan) (En).gb | RST38 トラップ/白 | ✅ タイトル画面描画(LCDC=$D3・メインループ IE=09 で待機) |
| Prince of Persia (Japan).gb | タイトルまでだったが停滞 | ✅ 序盤クレジット画面描画 |
| Pocket Monsters 赤 (Japan).gb | 黒画面 | ✅ タイトルロゴ+スプライト(©1995 GAME FREAK)描画 |

## 残課題

- BIOS 起動〜ハンドオーバが実機比でやや遅い(600F 窓内。60-120F かかる)。
  APU 待ち合わせが原因の可能性 → 要精密化。
- Mooneye スイートの採用(前回からの継続)。

---

# 追記(2026-10-19): 4 倍速バグ + Blargg 全 11 ROM Passed

## 5. `runFrame` が dots 残量に対して CPU の M-cycle 数を直接減算(4 倍速の正体)

- ユーザ報告「速度が速い・音もおかしい」の根因。`runFrame` は `dotsRemaining = 70224` を
  残量として保持するが、`stepWithBus:` の返り値は **M-cycle 数**(1 M = 4 dots)なので
  `dotsRemaining -= cycles` は単位不一致。結果 1 runFrame で 70224 **M-cycle** 分 CPU を回し、
  PPU/timer/APU は tick 毎に 4 dots 進むため、1 present フレームで **280,896 dots = PPU 4 フレーム分**
  進行していた(実機の 4 倍速)。
  - ゲーム内部時間・VBlank 割込みが 4 倍 → 演出/落下速度が速い
  - APU 波形・フレームシーケンサも 4 倍 → 音が 2 オクターブ上・テンポ 4 倍
  - サンプル産出が 48kHz の 4 倍量 → 200ms 上限切り詰めで音割れ
- 対応: 1 フレーム = 70224/4 = **17556 M-cycle** で CPU を駆動するよう修正。
- 検証: 600 runFrame の APU 産出量が `audio=10.046s / emu-time=10.046s, ratio=1.000`
  (修正前 ratio=4.000)。実物 GPUペース実測も 59.8fps 前後(実時間 10 秒)。
- 回帰テスト: `MBGameBoyTests.testRunFrameAdvancesExactlyOneFrameOfDots`
  (64 フレームで DIV が 17,556 進む)/ `testRunFrameEmitsAboutOneFrameOfAudio`(~1606 int16)。
- 注意: 以前の検証記録「600F で Tetris タイトル」は 4 倍速下での観測(実時間では 2400F 相当)。
  修正後は実時間レートのまま記録すること。

## 6. DAA 減算後(N=1)に C をクリアしていた(`MBCPU.m`)

- SM83 では N=1 の DAA で C は変化しない(初期値を保持)。旧実装は `F &= ~(H|C)` で
  C もクリア。blargg `01-special` #6 と `11-op a,(hl)` が Failed。
- 対応: 参照実装(BubiBoyLite `cpu_daa`)と同一のアルゴリズムに置換。
  `setC = carry` 初期で、N=1 では 0x60 補正時のみ C を維持。
- 回帰テスト: `testDAASubtractionPreservesCarry`。

## 7. `0x34/0x35`(INC/DEC (HL))が switch から欠落(NOP 扱い)

- `$E9/$E8` と同じ「未実装 → NOP」パターン。
  blargg `11-op a,(hl)` が Failed(`35 34`)、実 ROM のスコア/カウンタ処理にも影響。
- 対応: `case 0x34/0x35`(IncR/DecR idx=6, cycleCount=3)を追加。
- 回帰テスト: `testIncDecHLThroughMemory`。

## 修正後の Oracle 状態

- blargg cpu_instrs individual: **11/11 Passed**(修正前 9/11)。
- 最終検証(実 BIOS・実時間ペース・PPM→PNG 目視):
  Tetris 2400F タイトル / Pokémon 赤 9600F タイトルロゴ+スプライト /
  PoP 2400F クレジット画面。すべて実時間相当の進行で描画。

---

# 追記(2026-10-19 第2弾): APU 精密化 + NR52 ステータス + UI キービープ

## 8. APU が「レジスタの静的反映」相当で、音の長さ/減衰がおかしかった(ユーザ報告を再訪)

| 不具合 | 症状 | 対応 |
|---|---|---|
| length counter を全く進めていなかった | 音が止まらない/構成が崩れる | FS step 0,2,4,6 で減衰、trigger 時 max リロード |
| エンベロープの envStep を無視し 128Hz 減衰の乱用ステップ(旧 FS: step 3,7) | 減衰が速く「音長が短い」 | step 7 のみ(64Hz)+ envPeriod での間隔 |
| ch1 sweep(NR10)未実装 | スライド音程が実装されない | step 2,6 での clock + trigger 時 overflow 判定 |
| wave の trigger(NR34 bit7)で有効化されない | ch3(低音)が出ない | dacEnabled(NR30)化 + trigger リロード |
| noise 分周スケール誤り(divcode<<shift でなく (code+1)*2^shift に近い値) | ノイズ音程が高め | 除数表 {8,16,...,112} << shift |
| 出力 (sum-24)*1000 の int16 ラップ | 音割れ/DC バン | DAC 的 ± 加算(無音=0)、範囲 ±60 → ±30000 |
| **$FF26 NR52 読みでチャンネル状態ビットが 0 固定** | 音楽ドライバが再突入できず完全無音(Tetris 実測 nonzero 0%) | nr52Value を返すよう修正 |

検証: Tetris を Start 押下で 1P 開始後 2400 フレームの音声統計
- 修正前: `nonzero 0.0% rms=0`(完全無音)
- 修正後: `nonzero 94.9% rms=4910 peak=(−18500..19500)`(実時間ペース・実 BIOS)

回帰テスト: `testLengthCounterStopsChannel` / `testSweepOverflowDisablesChannelOnTrigger`
/ `testDACOffDisablesChannel`(MBCPUTests とは別、MBApuTests へ追加)。

## 9. キー入力で OS 警告音(NSBeep)が鳴る(ユーザ報告)

- 原因: MTKView が first responder としてキーを受け取れず、アプリの NSEvent モニタ後も
  イベントが responder chain まで届いて「未処理キー」のビープが鳴る。
- 対応:
  1. `MBEmulatorView`(MTKView 継承)を first responder にし、`keyDown/Up` を握りつぶす
  2. AppDelegate のモニタはゲームキー(修飾キー無し)を消費(nil 返し)。Cmd/Ctrl/Option
     併用はメニュー優先で WAS 消費しない
- ※ ユーザ側での耳での確認待ち(キービープ抑制)。
