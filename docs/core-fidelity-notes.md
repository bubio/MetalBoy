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

### Mooneye 結果(2026-10-19 第6弾時点)

**55/75 PASS**(52 → 54 → 55)。追加 PASS: stat\_irq\_blocking・stat\_lyc\_onoff・
intr\_2\_oam\_ok\_timing。intr\_2\_mode0\_timing は STAT ラインエッジトリガ化でも維持。

### 第6弾修正 11: APU IO レジスタの未使用ビット/書込み専用レジスタ読み値(2026-10-19)

Mooneye unused\_hwio-GS(期待表: 各レジスタ 2 回ずつ write=全ビット/0 で read\&mask 判定)を
HRAM 逆算ではなく**直接プローブ手法**(/tmp/mbhwio: write→read→mask 比較をメモリバスで実行)で
失敗レジスタを特定した。画面の字形解析(フォントタイル照合)は 2026 版 common の print 実装が
タイル番号を独自再配置するため不確実 → 静的照合+プローブで確定。

修正内容(MBApu.m readRegister/nr52Value):

- **NR44($FF23)**: 読みを 0x80 固定 → `0x3F | (lengthEnabled ? 0x40 : 0) | 0x80`
  (未使用 bit0-5 は常に 1)。Mooneye mask=0x3F の 2 件が FAIL だった本体。
- **NR52($FF26)**: nr52Value に未使用 bit4-6 を常に 1 追加(電源 OFF 中も 0x70)。
- **$FF18(NR23 相当)**: 0x00 固定 → 0xFF(書込み専用レジスタの読みは 0xFF。
  FF13/FF1D は default 経由で既に 0xFF)。
- **NR10($FF10)**: default(0xFF) → `0x80 | sweep 格納値`(bit7=1 + period/negate/shift)。

単体テスト `testUnusedIORegisterBits` 追加。**これで unused\_hwio-GS PASS(→ 56/75)**。

### 第6弾修正 12: LY=144 開始 dot の STAT mode2(OAM) 割込み(2026-10-19)

Mooneye vblank\_stat\_intr-GS: LY=143 からの NOP 数(54/55)で DIV 位相を測り、
VBlank 割込み(bit0)と STAT mode2 割込み(bit5 源)が LY=144 の同一 dot で立つことを要求。
round3/4(assert d/e)の失敗を mbtrace3(round 入口 + check\_asserts\_cb@failN ブレーク,
sym の `01:xxxx` は bank1 local=+0x4000 が実アドレス)で特定:

- 当方: LY=144 遷移 dot で mode=VBlank になり bit5 のライン条件(mode==OAMScan)が不成立 →
  bit5 による割込みが発火せず、不要な後段 LY=0 の mode2 エッジの stray 割込みで halt が解除
  → DIV 位相が 1 M-cycle ずれた値(0/1)になった。
- 修正: fireSTATIfRequest の m2 ウィンドウに `_ly == 144 && _mode == VBlank` を追加
  (VBlank 開始 dot で bit0 と bit1 が同一 dot の同時に立つ)。単体テスト
  `testSTATMode2InterruptAtVBlankStart`(RED→GREEN)を追加。**→ vblank\_stat\_intr-GS PASS(57/75)**。

### 第6弾修正 13: mode 3 長の SCX&7 依存伸縮(2026-10-19, 一部残置)

hblank\_ly\_scx\_timing-GS の実機データ: mode0(SCX&7) = 0→51M(204 dots) / 1-4→50M(200) /
5-7→49M(196)。すなわち mode3 長 = 172 + {0, +4(n=1-4), +8(n=5-7)} dots、mode0 は対応分短縮
(1 ライン合計 456 は不変)。MBPPU の OAMScan→Draw 遷移時に `_mode3Length` を SCX&7 から決定
し、mode0 閾値も `456 - 80 - _mode3Length` に。単体テスト testMode3LengthSCXExtension 追加
(172/176/180 を dot 計数で確認)。

**残置 FAIL の解析**(SCX&7=0.第 1 グループで delay=3 読みが LY=0x41 のまま):
テストの逆算サイクルは read cycle = t0(STAT int)から 48+delay M-cycle 目。実機は
delay=3 の read cycle が **LY 増分 cycle(51M 目)と同 dot** になり新値(LY=0x42)が読める。
当方は同 dot でも 1 M 早い(増分前の 0x41 を返す) = **CPU の割込みディスパッチ開始または
バス tick の位相が実機より 4 dots(M-cycle 1 個)遅れて観測される**。dispatch=5M・ADD SP,r8=4M・
RET=4M・CALL=6M・NOP=1M・LD A,(HL)=2M は全て実機一致済みのため、残る候補は
「HALT 解除→ディスパッチの検出タイミング(PPU tick が M-cycle 中で IF を立てる位置)」の
M 境界位相。intr\_2 系 per-dot パイプライン移植時に CPU/PPU 位相契約と共に再検証する。

### Mooneye 結果(2026-10-19 第6弾修正 11-13 時点)

**57/75 PASS**(55 → 56 → 57)。追加 PASS: unused\_hwio-GS・vblank\_stat\_intr-GS。
単体テスト 74/74 GREEN。リグレッションなし(/tmp/mooneye\_results11.txt)。

### 第7弾修正 14: LCD ON 直後の死相(boot phase)実装(2026-10-19)

lcdon\_timing-GS 検証のため MBPPU に LCD OFF→ON 遷移の死相boot phase を実装した。
実装: `setLcdc:(uint8_t)` を新設し(off→on 遷移で `_lcdBootDots = 84` を設定)、
`tickDots:dots:` の dot ループ先頭で

- 死相中: `_ly = 0` 固定・`_mode = HBlank`(モード読出し 0)・`_dotsInMode = 0`。
  OAM/VRAM はともに読み書き可(HBlank 相当)。
- 死相終端 dot で `_mode = Draw`・`_dotsInMode = 0`・`_bootHBlankDots = 196` を設定し、
  HBlank 閾値置換で line0 の mode0 = 196 に短縮。

**実測定数(lcdon\_timing-GS から反復較正)**:

| 区間 | dots | 根拠 |
|---|---|---|
| 死相(LCD 書込み後) | 84 | STAT\_LYC0 pass1 s1-2(c=17/60)が 0x84(モード 0)のまま |
| line0 mode3 | 172 | 同左(s2 で 0x87=mode3) |
| line0 mode0 | 196 | LY pass1/pass2/pass3 s3(c=110/111/112)の 00/01/01 の 4-dot 窓 |
| **line0 合計 / LY 増分** | **452** | 単体テスト testLCDOnBootPhase で 452±8 域 |
| line1 以降 | 456(通常) | LY pass1 s4 以降 |

テスト構造: 5 グループ(LY / STAT LYC=0 / STAT LYC=1 / OAM / VRAM)× 3 パス
(NOP 0/1/2 = 読み取り dot を ±4 dot シフト)× 8 サンプル(c = 0/17/60/110/130/174/224/244)。
ROM 無パッチで 1 実行 = 1 判定点(fail\_round/fail\_expect/fail\_actual を HRAM $FF98-9A から読む、
mbLcdonFail)。検証には `jp nz, verify_fail` を NOP 化し pass3 末尾 jp を collect ルーチン
(24 byte 結果を $C000+g*24 へコピー + カウンタ $FF99 += 24)へ差し替える全観測値採集法
(mbLcdon)も用意済みだが、現時点では 1-dot 反復較正で十分な速度のため未使用。

**進捗(lcdon\_timing-GS)**: LY グループ pass1 = 24/24 中 8/8 完全一致、STAT\_LYC0 pass1 も
最初 5 サンプル一致(s1-2 = 84/84 死相、s3 = 87 mode3)。残置 FAIL は **line1 以降の位相**
(s5(c=174)で exp=83(mode3) vs got=80): 実機は line 以降の位相境界が +4〜8 dot ドリフト
する(ソースコメント "PPU is late by 2 T-cycles")。line1 の mode2/mode3 境界定数の
反復較正が次の作業。単体テスト testLCDOnBootPhase 追加済み、Mooneye 他 75 本は
リグレッションなし(基準 57 PASS と同一)。

### Mooneye 結果(2026-10-19 第7弾修正 14 時点)

**57 PASS / 17 FAIL / 1 判定不能**(sources-GS はソース出力 ROM で判定なし)。
基準計測(git stash 相当)と FAIL 一致 = リグレッションなし(/tmp/mooneye\_results13.txt,
600 フレーム条件)。前回計測との 60/75 表記差は計測条件差で、FAIL 集合は同一と判断。

### boot クラスタ詳細計測(2026-10-19, 未解決)

### 第6弾修正 8: STAT 割込みラインのエッジトリガ化

`_statIrqLine` ivar で STAT 割込み要求ライン(型: 立込み時のみ IF bit1 を 1)。
LCD OFF 中は `(stat & 0x40) && _coincidenceLatch` で駆動。これで
stat\_irq\_blocking(STAT bit 連続書込みで朝起き割込みが潰れる挙動)と
stat\_lyc\_onoff(LCD OFF 中 4 ラウンドの LYC 比較)が PASS。

併せて:

- STAT bit7 を常に 1 に(DMG 仕様)、LCD OFF 中モードビット=0・bit2=`_coincidenceLatch`
  の凍結値(`statValue` = `0x80 | (stat & 0x78)`)。
- `_coincidenceLatch`: LCD ON 中は毎 dot で `ly==lyc` を保存、OFF 中は凍結。

### 第6弾修正 9: JOYPAD $FF00 の registerLatch 化とパレット電源投入既定

- `selectDirectionKeys/selectButtonKeys` BOOL を廃止し `registerLatch`(0x30 マスク)に統一。
  ioRead は bit7/6=1・bit5/4=ラッチ値・bit3-0=ラッチ駆動行(bit=0 駆動)の押下 OR。
  電源投入既定 = **0x00**(DMG BIOS handover 値 $CF と整合; BIOS は P1 を書かない)。
  ioWrite FF00 は `registerLatch = value & 0x30`。
- PPU OBP0/OBP1 電源投入既定を 0xE4 → **0xFF**(BGP=0xFC は据え置き)。

### 第6弾修正 10: mode 3 中の OAM ロック(2026-10-19)

実機では mode 3(Draw)中の CPU による OAM アクセスは不可(読みは 0xFF、書込みは捨てられる)。
`MBPPU.readOAM/writeOAM` に `(lcdc & 0x80) && _mode == Draw` のゲートを追加
(内部レンダリングの `_oam` 直参照には影響しない。LCD OFF 中はモード凍結によりアクセス可)。
OAM DMA 転送経路(writeOAM 直接呼び出し)はゲート外のまま。

これで `intr_2_oam_ok_timing`(mode2 STAT 割込みから OAM 再アクセス可能点を測定)が PASS。
OAM アンロック点 = mode0 遷移点と同一 dot で実機と整合(intr_2_mode0_timing と同一の
delay 46/45 構造で実測)。

### intr_2_mode0_timing_sprites の分析(未通過, 本丸)

スプライト構成による mode 3 伸長(スプライト毎 +4/+8 dots、ストラック・8 間隔配置で
最大 +108 dots)の精密モデルが必要。要件を精査した結果:

- テーブルの expected 値 X は sled 長 `41+X` / `40+X` NOP の差分 → mode3 伸長は
  **4 dot 粒度**で判定される。
- この precision(±4 dots)を出すには SameBoy 相当の per-dot OBJ フェッチパイプライン
  (7 状態フェッチャ + PUSH は fifo 空まで待つ + OBJ 注入 seek+6dot、inline_const テーブルの
  歴 年 検証済みモデル)の移植が必要。現行の固定 80/172/204 mode モデルでは表現不能。
- 計画: /tmp/mscp_harness.py(試作シミュレータ)で SameBoy pipeline を模倣したが
  SameBoy 内部の line-base 位相や renders-shin 境界を精確に再現しきれず未完。
  次ステップ: SameBoy Core/display.c の mode3 ループを dot 粒度で忠実に MBPPU に写像する
  設計が必要(モード遷移・STAT/LYC・renderCurrentScanline 位置との整合に細心の注意)。
  実装は大規模( raccourci: 500 行〜)のため、他の未通過クラスの精密化が終わってから着手する。
- スプライト OAM X マッピング: OAM X = LCD x + 8(左端 pixel = X-8)。
  OAM X=0 → 左側完全オフ画面でも penalty 発生(+8 dots)、X≥168 → penalty なし。

### boot クラスタ詳細計測(2026-10-19, 未解決)

所見: 構造は実機相当、しかし BIOS 全体の実行長が実機想定より ~+6,269 dots(mod 65,536)長い。

mbboot3(ラップ補正 TRUE dots 計測)による断:

- boot\_div-dmg0 の DIV 読み(pc 0x017F/01BB/01F6/0232/026E/02AB の直後 A):
  実測 **$31,$32,$33,$34,$35,$36** = divCounter 12684/12940/13192/13448/13704/13964。
  gap = 256/252/256/256/260 dots = 64/63/64/64/65 M — **相対構造は完璧(CPU M 割出し OK)**。
- 期待値(regs\_assert $FF89-90): B=$19 C=$1A D=$1A E=$1B H=$1C L=$1E。
  目標リード1位相 ≡ 6401..6403 dots(mod 65,536)⇒ ハンドオーバ位相 ≡ **~6,185**。
- 実測ハンドオーバ(pc 0x0100 fetch): **dots=24,785,064 ≡ 12,456 (mod 65,536)**、
  DIV byte = $30。**差 = +6,269 dots ≈ +6,144(+1536 M)+~130** — boot\_hwio FF04($19 期待/$31 実測)
  と同値系列。
- BIOS 内ステージ: power-on → LCDON(pc 0x006B)は 269,932 dots(LCDC=$91 が電源投入既定なので
  実質 no-op)、D ループ **132 ITER**(LD D,$64=100 + LD D,$20=32 の 2 相)、各 ITER は
  SUB($00BC, e=2) を 1 回 + 残り code ≈ 128 dots。LCDON → h 24,515,132 dots = 349.1 frames。
- SUB 内部(DEC C 連鎖): 44 dots 間隔で LY144 ウィンドウ内 8〜10 連鎖 → 残りは **FULL-FRAME
  spin**(~69,804 dots を wrap 差引きで確認: mod 表記上 4,268 dots の間隔 = 4,268+65,536)。
  つまり sub 構造 = 実機演算と同一(12 decs = 528 dots > 456 ウィンドウなので 8〜10 連鎖 +
  1 フレーム待ちの断)。
- **未解決の本質**: 全体が実機想定より ~+6,269 dots(mod 65,536)長い。sub・D ループ・
  相対 M 構造は全て整合しているため、残る候補は「実機 DMG0 の電源投入時ラインクロック位相
  (我々の dot 0 = LY0/dot0 とする仮定)」程度。gb-ctr(WIP)には電源投入位相の記載がないため
  ハードオラクル無しには確定できない。
- 併せて: boot\_regs-dmg0 PASS・boot\_hwio は FF04 のみ mismatch($31 vs $19)。FF00=$CF も PASS
  (修正9の効果)、FF40/47/50・IE も PASS。


### 修正 15:lcdon_timing-GS 完全 PASS = LY 増分・LYC 比較・OAM/VRAM 禁止窓の全面再較正(2026-10-20)

lcdon_timing-GS を反復較正(mbLcdonFail)し、以下を「実測解」として MBPPU に実装した。

**(A) LY 増分を HBlank 終端の 4 dot 前に移動**。以前は HBlank 終端(= 次 line の
mode2 開始と同 dot)で LY++ していた。実測: LY pass2 s3 の期待 01(増分済み)と
STAT\_LYC1 pass2 s3 の期待 80(LYC=1 なのに coincidence 無し)が同一 dot で共存するのは、
増分が窓 [452,456) で既に効いているから。hblank\_ly\_scx\_timing-GS の 51/50/49 M データ
(LY 増分 = mode0 開始 + (mode0長 − 4))とも完全整合。実装: HBlank case 内
`_dotsInMode == threshold - 4 && _ly <= 142` で LY++(VBlank 遷移 143→144 は従来通り
終端 `_dotsInMode >= threshold` で同時)。**副産物: hblank\_ly\_scx\_timing-GS が PASS**。

**(B) LY 増分直後 4 dot は STAT bit2(coincidence)強制 0**。STAT\_LYC0/LYC1 の
pass2 s3 がともに 0x80(リード値同 80 ID ど副)→ 自然比較(C0 依存で解析)ではどちらか一方しか
説明できず双方 0 が唯一の整合解。`_coincBlanked`(増分 dot で立つ、threshold で消える)。

**(C) OAM/VRAM 読み出しは mode FSM でなく「窓」で判定**(lcdon_timing-GS OAM/VRAM 群
120 観測値すべてと整合)。ddsi = 窓 anchor(LY 増分 dot、line0 は LCD ON dot)からの dots:

```
OAM  禁止: line0(死相) = [anchor+80, anchor+252) / 通常 = [anchor, anchor+256)
VRAM 禁止: [anchor+80, anchor+252)(line0) / [anchor+80, anchor+256)(通常)
   端末解放 = mode0(HBlank)開始 dot、開始側は可視 mode3/mode2 の 4 dot 前
   (mode2 が無い line0 は mode3 そのまま)。VBlank(mode1)中は無条件に読可。
```

検証例: line1 で VRAM は dsi 76-79(=528-531)が 00 / dsi 80-83(=532-535)が FF
(可視 mode3 536 の 4 dot 前からロック)、OAM は dsi 252-255(=704-707)が FF /
dsi 256+(=708+)が 00 → 両窓の非対称が同一 dot の OAM/VRAM 読みで実測される。
mode2 中の OAM 読み 0xFF もこの窓則に含まれる(以前の mode3 のみ実装を置換)。

**(D) 電源投入も死相から開始**(init: `_lcdBootDots = 80`, `_bootWindow = YES`,
`_mode = HBlank`)。実機の電源投入 LCDC は $91(LCD on)のため off→on 遷移待ちではなく
init 時点で死相状態。**副産物: boot\_regs-dmgABC が PASS**(死相 LY=0 固定が BIOS
ランタイムの初期待値に一致)。ただし **boot\_regs-dmg0 は FAIL に変動**(要確認)。

**CdNN 結果(unused Mooneye 75 本、600F): 59 PASS / 15 FAIL / 1 判定不能**(修正前 57/17)。
lcdon\_timing-GS・hblank\_ly\_scx\_timing-GS・boot\_regs-dmgABC の +3。
単体テスト testLCDOnBootPhase・testOAMLockedDuringMode3(mode2 で読み 0xFF 期待に改訂)・
testSTATMode2InterruptAtVBlankStart(LY=143 初観測が 4 dot 前になったため 459+1 dot に改訂)。

### 修正 16: OAM/VRAM 書込み禁止窓(実機。lcdon_write_timing-GS PASS)(2026-10-25)

lcdon_write_timing-GS(LCD ON 直後の OAM/VRAM「書込み」可否を 19 位置×2 で確認)
を HRAM fail_round ダンプ + 期待表 4-dot 解析(mbLcdonWrite)で攻略した。
書込みドット W(n) = 4n + C0(n = nop 数)、C0 ∈ [8,12)(読出し較正と同一幅)で
期待 19×2 = 38 件すべて整合。実測から確定した書込み窓(dsd = dsi anchor からの dots):

```
OAM  書込み捨て: line0(死相) = [anchor+80, anchor+252)(読出しと同一)
                通常 line    = [anchor+4, anchor+80) ∪ [anchor+84, anchor+256)
                  (mode2 前 76 dot と mode3。mode2 最後の 4 dot [80,84) は書込み可)
VRAM 書込み捨て: line0 = [anchor+80, anchor+252)(読出しと同一)
                通常 line = [anchor+84, anchor+256)(= 可視 mode3 のみ。
                  mode2 窓(raster<80)は書込み可 = 読出し([80,256))より START 側 4 dot 緩い)
VBlank(mode1)中は無条件に書込み可。
```

代表作例: 通常 line の dsd 4(D)は OAM 書込み捨て/VRAM 可、dsd 80(D)は OAM 可、
dsd 84(D)は両方捨て(raster では OAM 76 で可/80 で不可、VRAM 80 で不可)。
検証: lcdon_write_timing-GS **PASS**。
単体テスト: testOAMWriteLockedAtLcdOn / testOAMWriteLockedDuringMode2NormalLine /
testVRAMWriteLockedDuringMode3 追加、testOAMLockedDuringMode3(mode2 前 76 dot の
書込み捨てに改訂)、testLCDOnBootPhase(残っていた死相 84/mode0 196 の旧定数コメントを
80/204 に整備)。

**boot 系 BIOS 供給計測の確定**: mbmooneye_bios(実 BIOS = DMG0 リビジョン)で
boot_regs-dmg0 **PASS**、boot_regs-dmgABC は BIOS なし電源投入レジスタの再現で PASS
(実 BIOS の最終レジスタとは別モデルの期待値のため FAIL)。修正 15 直前コミット
(48225bc)でも boot_regs-dmg0 PASS を再現し、「修正 15 で FAIL 化した」のは
BIOS なしランナーでの分類差(偽リグレッション)であったこと解決。
boot_div/boot_hwio-dmg0(実自動実装で本来 PASS し得る)は FAIL のまま:
BIOS 起動中の DIV 観測 = 32 31 34 33 36 35(期待 19 1A 1A 1B 1C 1E)=
起動総 M 数のずれ(PPU 実装 LY 待ちループ?) + DIV 位相差で、電源投入位相
オラクルなしに確定不能のまま(boot クラスタ分析打ち切り維持)。

隣接計測(修正 15 の定数・窓が intr_2 系を壊していないか): intr_2_oam_ok_timing /
intr_2_mode0_timing は修正 16 後も PASS(修正 15 隣接再計測 1 回は必須化条件を消化)。

**Mooneye 結果(2026-10-25 修正 16 時点、75 本): 60 PASS / 13 FAIL / 2 判定不能**
(lcdon_write_timing-GS +1。60/13 に移行。bios 供給で boot_regs-dmg0 が PASS の点を
含めた「実質』の見取り図: (BIOS なしランナー: 60/13/2)。なお /tmp 清掃により
再構築: mooneye-test-suite(WLA-DX, brew wla-dx)/ mbmooneye・mbmooneye_bios・
mbLcdonWrite(再リンク手順は同じ)。

### 観測メモ: Tetris の約 40 秒以降の無音

変更前後で同一のため DMA 修正の影響ではない。1200F(20秒)では BGM nonzero 88.8%。
4800F(80秒)以降は APU 出力が完全に 0 になる。APU の長時間再生での何か(チャンネル停止?
length カウンタ悪用? または検証ツール側の録音区間の問題)が疑われるため、
次の調査候補として残す。

### 既知の未通過(精密化バックログ)

- **boot\_div/boot\_hwio/boot\_regs-\*・boot\_sclk\_align(-dmgABC/mgb/-S/-sgb\*)**: BIOS
  ハンドオーバ時のレジスタ/DIV 値の実機一致性。**boot\_regs-dmg0 は PASS(実 BIOS
  供給ランナー・修正 16 確定)**。BIOS なし電源投入値は dmgABC 群相当のため
  dmg0 期待値と一致しない(では BIOS なしランナーでは常に FAIL、分裂は正常)。
  boot\_div・boot\_hwio は上記詳細計測の通り ~+6,269 dots の位相差のみ。
  ハードオラクル(実機の電源投入時ライン位相)が得られない限り一旦 close
  (boot\_regs-dmgABC/mgb/sgb/sgb2 は複数モデルの BIOS 差分のため要ランナー対応)。
- **unused\_hwio-GS**: **PASS(修正 11)**。FF23/FF26/FF18/FF10 の読み値を修正。
- **PPU GS クラスタ**: vblank\_stat\_intr-GS **PASS(修正 12)**。残り:
  - lcdon\_timing-GS: **PASS(修正 15)**。
  - hblank\_ly\_scx\_timing-GS: **PASS(修正 15 — LY 増分 4 dot 前倒し)**。
  - lcdon\_write\_timing-GS: **PASS(修正 16 — OAM/VRAM 書込み窓)**。
- **intr\_2\_mode0\_timing\_sprites**: **PASS(修正 17 — OBJ penalty 式)**。
- **rapid\_di\_ei**: 参照実装でも既知の難関、後回し。
- **Tetris 約40秒以降の無音**(上記観測メモ)。

### 修正 17: OBJ による mode 3 伸長(2026-10-26)

per-dot OBJ フェッチパイプラインは不要だった。mode 3 開始時に Pan Docs の OBJ penalty 式で
伸長 dots を求め、M-cycle 単位に切り捨てて `_mode3Length` に加算する(`spritePenaltyDots`)。

- 対象: OAM 順で line に掛かる最大 10 体のうち X<168(LCDC bit1=0 なら 0)
- BG タイル(`(X + SCX&7) >> 3`)ごとに最初の 1 体は `11 - min(5, (X+SCX)&7)`、同一タイルの
  2 体目以降は 6 dots
- `4 * floor(合計/4)` が intr\_2\_mode0\_timing\_sprites の extra cycles 表全 100 ケースと一致
- SCX 伸長(切り上げ)と OBJ 伸長(切り捨て)の丸め方向は異なる。SCX≠0 かつ OBJ ありの
  組合せは Mooneye に検証ケースがなく未検証
- per-dot パイプライン試作(旧 WIP: 修正 19/20 を含む)は timer/PPU で 8 本退行(53/75)したため破棄

**Mooneye 結果(修正 17 時点): 61 PASS / 12 FAIL / 2 TIMEOUT**(intr\_2\_mode0\_timing\_sprites +1、退行なし)。
単体テスト 79/79。

### 修正 18: HALT バグ(2026-10-27)

- 症状: blargg halt_bug.gb が `Failed`。IE/IF 保留ありの行で `0411` になるべき値が `0C04`
- 原因: IME=0 かつ `(IF & IE) != 0` で HALT を実行したとき、停止せずに直後のバイトを
  PC を進めずに 2 回読む実機挙動(Pan Docs "HALT bug")が未実装
- 修正: `MBCPU` の HALT で条件成立時は halt せず `_haltBug` を立て、次の `CPUFetch8` で
  PC インクリメントを 1 回抑止。回帰テスト `testHaltBugReadsNextByteTwice`
- 結果: halt_bug `Passed`、Mooneye 61/75 維持、cpu_instrs / instr_timing / mem_timing 維持

### 修正 19: Mooneye 61 → 66/75(2026-10-27)

| テスト | 原因 | 修正 |
|--------|------|------|
| rapid\_di\_ei | EI 直後の DI が遅延中の IME 有効化を取り消さない | DI で `_imeApplyAfterInstruction` もクリア |
| oam\_dma/sources-GS | MBC5 の電源投入時 ROM バンクが 0(`$4000` 実行で RST 38 ループ)。DMA ソース `$E000-$FFFF` を WRAM へミラーしていない | `_romBankLow = 1` で初期化。`dmaRawRead` で `$E000` 以上を WRAM ミラー |
| boot\_div / boot\_hwio-dmgABCmgb | BIOS なし起動が BIOS 終了時の I/O 状態になっていない。NRx4 の読み出しマスク誤り | 各コンポーネントに post-boot 状態(IF=$E1・DIV 内部 $ABCC・BGP=$FC・ch1 有効/音量 0)。NRx4 は `$BF \| length enable` |
| serial/boot\_sclk\_align-dmgABCmgb | シリアル転送が即時完了・割込みなし | 内部クロック時は DIV 内部カウンタ bit8 の立下り毎に 1 bit、8 bit で IF bit3。外部出力は CPU が SB に書いた値(Mooneye quit は転送完了前に次の SB を書くため)。ランナー判定を末尾 6 バイトに変更 |

- 実 BIOS 供給時(`--bios`)は `buildComponentsPostBoot:NO` で電源投入状態から作り直す
- 残り 9 本は全て DMG 以外のモデル(dmg0 / S / mgb / sgb / sgb2)向け。本機の対象(DMG ABC)では FAIL が正しい
