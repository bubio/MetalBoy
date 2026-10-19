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

## 10. M-cycle 割出し CPU + OAM DMA 逐次転送エンジン(2026-10-19 第3弾)

### 背景: Mooneye テストスイートの採用

Gekkio mooneye-test-suite の prebuilt ROM(`https://gekkio.fi/files/mooneye-test-suite/`
mts-20260714-0944-31510e1、acceptance 75 本)をオラクルとして追加。
判定は quit プロトコルのシリアルダンプ成功 = `03 05 08 0D 15 22`(Fibonacci)、
失敗 = `42`×6。検証ツールは `/tmp/mbmooneye.m`(実 ROM デバッグ用でプロダクトに含めない)。

引き上げ前ベースライン: **10/75 PASS**。

### 修正 1: 命令ごとの合計 M-cycle 値の修正

- ALU $80-$BF reg→reg が一律 2 → reg は 1、(HL) 参照は 2
- CB 命令が一律 2 → BIT は reg=2/(HL)=3、rotate・RES/SET は reg=2/(HL)=4
- POP $C1/$D1/$E1/$F1 が 4 → **3**

### 修正 2: M-cycle 単位のバス操作割出し(stepWithBus の全面改修)

従来は命令実行後の最後にまとめて N M-cycle をバスへ供給しており、命令内の
「どの M-cycle でメモリアクセスが起こるか」が実機とずれていた。
実機位置合わせへ作り直し:

- **すべてのバス操作の直後に 1 M-cycle を emit**(命令フェッチ込み)。
  `_ticksDone` で命令内の既 emit 数を追跡し、最後に内部遅延分のみ追加送出
  (`finishTicks`)する。
- メモリアクセスを伴わない M-cycle(内部遅延)は実機位置で挟む:
  PUSH/CALL/RST は「opcode → 内部 M → w,w」、RET cc(taken) は
  「opcode → 内部 M → r,r → 内部 M」、割込みディスパッチは
  「内部 M×2 → PC push → 内部 M」。
- tic 型は Pan Docs / BubiBoyLite の各命令 M-cycle 表と突き合わせ済み。

### 修正 3: OAM DMA($FF46)の逐次転送エンジン

`MBMemoryMap` に状態機械を実装(BubiBoyLite `bus.odin dma_tick_one_mcycle` 準拠):

- $FF46 書込みで `dmaStartDelay=2` セット。M2 で旧転送を打ち切って新規転送開始。
- 1 バイト/M-cycle で 160 M-cycle かけて :source 読出 → OAM 書込。
- **バス競合**: DMA 中の OAM($FE00-$FE9F)への CPU 読み出し=0xFF、書込み=無視。
  (HRAM・IO・WRAM・VRAM 等は通常どおり可能。BubiBoyLite の改良版モデルと同一)
- DMA 自身のソース読み出しは競合ゲートを素通り(dmaRawRead)。
- $FF46 読み戻しは「最後に書き込んだ値」を返す(Mooneye reg_read 仕様)。
- 付随修正: 旧実装は OAM 領域への直接読み書き(ioRead/ioWrite 経由)が完全に落ちていた
  ので実装(PPU readOAM/writeOAM に接続)。

### 修正 4: OAM DMA の byte 書込み位置の 1 M-cycle 精密化(2026-10-19 第4弾)

`oam_dma_restart`(以後 39 回の dec/jr ループから `ld a,(hl)`)が失败していたため、
一時計装(環境変数 MB_DMA_LOG ゲート、プロダクトからは削除済み)で byte 書込みの
絶対 M 位置と CPU OAM 読み出し位置を可視化して特定した:

- **旧実装**: 開始(delay=0 消化)の tick で active 化 **と byte0 書込み**を同 tick で
  行う byte k = M\_{w+1+k} に載る。このため byte159 の書込み M/読出し FF ウィンドウ
  が 1 M-cycle 早く閉じ、テスト想定の「最終 byte の M そのものに重なると FF」が満たない。
- **新実装**: 開始 tick では active 化のみ(隔離 1 M)、byte0 は次の tick から。
  byte k は M\_{w+2+k} の終端 tick で OAM に載る。
  - 読出し FF ウィンドウ = **M\_{w+2}..M\_{w+161}**(byte159 の書込み M そのものまで FF、
    その 1 M-cycle 後は載った値を読める)
- これで `oam_dma_restart`・`oam_dma_timing` が PASS。
- **push_timing**(DMA 完了直後に PUSH し、書込みが捨てられるか確認するテスト)も
  通過。書込み側の判定は読出し FF ウィンドウ(dmaActive)と同一で、追加テールは不要
  と確認した。

調査中に「書込み抑止テール(+4 M-cycle)」を一時実装したが、`start_oam_dma` マクロ内の
`wait_vblank` とその直後の `ld a,39`(2M)+ 39 回ループ(38×4+3=155 M-cycle)を正しく
数え直すと push の M2/M3 書込み位置は M\_{w+161}/M\_{w+162} となり、既存ウィンドウと
一致するため撤去した。

回帰テスト: `Tests/MBMemoryMapDMATests.m`(新規 3 本、計 69 本に増加)。

### Mooneye 結果(2026-10-19 第4弾時点)

**38/75 PASS**(23/75 → 38/75)。追加 PASS:
oam\_dma\_restart・oam\_dma\_timing・push\_timing・add\_sp\_e\_timing・
call\_timing・call\_timing2・call\_cc\_timing・call\_cc\_timing2・
jp\_timing・jp\_cc\_timing(命令 timing クラス 10 本)。

引き続き `blargg cpu_instrs 11/11`・単体テスト 69/69・Tetris 音声統計(1200F/2400F)を
変更前とビット単位で同一を確認(リグレッションなし)。

### 修正 5: EI 遅延 IME の適用位置精密化(2026-10-19 第5弾)

実機: **IME は EI の翌命令の「完了後」に立つ**。旧実装は翌命令の「開始時」に
適用し同一ステップでディスパッチ判定をしていたため、EI 直後の境界で割込みが
1 命令早く発火(B=$00 のまま $0058 に入る)した。`ei_timing` の PC トレース
(/tmp/mbtrace: MBCPU サブクラス + KVC で全ステップ記録)で特定:

- 修正: `stepWithBus` 冒頭で EI 遅延フラグを `_imeApplyAfterInstruction` に積み替え、
  適用を `finishTicks`(全命令パスの必経点、CB/LD/ALU 即値群の早期 return 含む)で行う。
  早期 return 直接テールに置くと ALU 系命令が途中でスキップして IME が永遠に立たなく
  なる(halt\_ime1\_timing が halt のまま固まる)ため必経点に置くのが要。
- 連鎖 EI(ei\_sequence)は「EI#1 で待機→EI#2 完了後に IME 立つ→EI#3 直前の境界で
  ディスパッチ(push PC=$01A2)」で解決する。
- ei\_timing・ei\_sequence・reti\_intr\_timing が PASS。reti の即時 IME(RETI は
  遅延なし)は既存実装どおり。

### 修正 6: 割込みディスパッチ最中の IE 書換(ie_push)(2026-10-19 第5弾)

ディスパッチを「M1,M2 内部 → 上位 byte push(SP-1、$FFFF=IE への衝突あり) →
**上位 push 直後に (IF & IE) 再評価** → 下位 byte push(SP-2) → ベクタジャンプ+IF
クリア+内部 M」に改修:

- 再評価が 0: **ディスパッチ中止**(下位 push なし・IF クリアなし・PC=$0000・
  IME=0 のまま)。ie\_push round1(上位 push の IE 書換 $02 で TIMER ビット消失)実現。
- 再評価が非 0: **再優先決定**(round4: VBlank が消されて STAT が選ばれる)。
- 下位 push 中の IE 書換は再評価後のため取り消されない(round3)。
- PC push の分割化に伴い `CPUPush16` は通常命令用のまま、ディスパッチは手分割。

### 修正 7: タイマの立下りエッジモデル全面書き直し(2026-10-19 第5弾)

旧実装は DIV 内部カウンタと独立した period カウンタ(timerCounter)で TIMA を刻んで
おり、DIV/TIMA 位相が独立していた。実機は:

- **16bit 内部 dot カウンタ(+4/M)が共有**。DIV=$FF04 読み = カウンタ >> 8。
- TIMA は **TAC 選択ビット {4096Hz:bit9 / 262k:bit3 / 65536:bit5 / 16384:bit7} の
  立下りエッジ(1→0)** で +1(DOT 粒度: 最初の立下りは 2^(b+1) dot 後 = 各周期的と一致)。
- TIMA=$FF でエッジ → **$00 停止 1 M-cycle → リロード(TMA)+IF bit2**。
- **オーバーフロー M 中の TIMA 書込み = オーバーフロー自体をキャンセル**
  (値が有効・リロードも IF もなし)。**リロード M 中の TIMA 書込み = 廃棄**、
  **リロード M 中の TMA 書込み = 新値が TIMA へ即反映**。
- **DIV 書込み = カウンタ 0 化 + 選択ビット立上り時は即エッジ**(tim\*\_div\_trigger)。
- TAC 書込みでも clock line(enabled && 選択ビット)の 1→0 でエッジ。

これで timer クラスタ **12 本(tim00/01/10/11・4 件の div\_trigger・
tima\_reload・tima\_write\_reloading・tma\_write\_reloading・div\_write・rapid\_toggle)が
PASS**(旧 tim01 のみから 12 に)。
`rapid_di_ei` は引き続き未解決。

### Mooneye 結果(2026-10-19 第5弾時点)

**52/75 PASS**(38/75 → 52/75)。追加 PASS:
ei\_timing・ei\_sequence・reti\_intr\_timing・ie\_push・div\_write・tima\_reload・
tima\_write\_reloading・tma\_write\_reloading・tim00・tim10・tim11・
tim00\_div\_trigger・tim01\_div\_trigger・tim10\_div\_trigger・tim11\_div\_trigger・
rapid\_toggle。

### 観測メモ: Tetris の約 40 秒以降の無音

変更前後で同一のため DMA 修正の影響ではない。1200F(20秒)では BGM nonzero 88.8%。
4800F(80秒)以降は APU 出力が完全に 0 になる。APU の長時間再生での何か(チャンネル停止?
length カウンタ悪用? または検証ツール側の録音区間の問題)が疑われるため、
次の調査候補として残す。

### 既知の未通過(精密化バックログ)

- **指示 timing クラス**(ret/rst/ei/intr 系): ei\_timing・ei\_sequence・reti\_intr\_timing・
  ie\_push は未通過。割込みディスパッチ/IME 更新タイミングの 1 cycle 精度が要る。
- **timer クラス**(tim00/tim10/tim11・\*\_div\_trigger の一部・tima\_reload・div\_write):
  DIV/TIMA の立下り位相整合。rapid\_toggle・rapid\_di\_ei は参照実装でも既知の難関。
- **boot\_div/boot\_hwio/boot\_regs-\*・boot\_sclk\_align**: BIOS ハンドオーバ時の
  レジスタ/DIV 値の実機一致性。
- **PPU stat/LCD 系**(stat\_irq\_blocking・lcdon\_timing・\*-GS 等): PPU 精密化後の課題。
- **Tetris 約40秒以降の無音**(上記観測メモ)。
