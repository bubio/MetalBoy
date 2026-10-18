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

| ROM | 修正前 | 修正後 |
|---|---|---|
| Tetris (Japan) (En).gb | RST38 トラップ/白 | ✅ タイトル画面描画(LCDC=$D3・メインループ IE=09 で待機) |
| Prince of Persia (Japan).gb | タイトルまでだったが停滞 | ✅ 序盤クレジット画面描画 |
| Pocket Monsters 赤 (Japan).gb | 黒画面 | ✅ タイトルロゴ+スプライト(©1995 GAME FREAK)描画 |

## 残課題

- Tetris のキー入力 → タイトル遷移の確認(`press` 引数での PLAY 検証)。
- BIOS 起動〜ハンドオーバが実機比でやや遅い(600F 窓内。60-120F かかる)。
  チム rendering待ちの APU 待ち合わせが原因の可能性 → 要精密化。
- Mooneye スイートの採用(前回からの継続)。
