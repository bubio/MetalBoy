# テスト ROM(標準テストスイート一覧)

SC-007(テスト ROM の合格)で使用するスイートと合格基準の一覧。
本リポジトリは ROM を同梱・配布しない(restore: 入手はユーザー側で行う)。

## ROM パスの指定方式

テスト ROM は **外部パス指定のみ**。リポジトリ内に置かない
(`.gitignore` の `*.gb` / `*.gbc` 除外ポリシー)。

```sh
# 実行形式(ランナーは Sources/Tools/TestROM/main.m・ターゲット metalboy-testrom)
metalboy-testrom /path/to/<suite>.gb --frames <N>

# --frames を省略した場合は 1800 フレーム(約 30 秒)駆動する
```

- ランナーはシリアル出力(SB `$FF01` / SC `$FF02`)を blargg 形式
  (先頭 `$81`)として収集し、以降のテキストを stdout に出力する
- 終了コード: `0`=正常終了、`1`=起動・セーブ・実行エラー、`2`=引数エラー
- 合格判定: 出力テキストに `Passed`(`Passed.` も同様)が含まれること

## 使用するスイート一覧(SC-007 の合格基準)

| スイート | 実行例 | 期待するシリアル出力 |
|---------|--------|------------------|
| blargg cpu_instrs(各サブテスト) | `metalboy-testrom /path/to/cpu_instrs/01-special.gb --frames 900` | `Passed` |
| blargg instr_timing | `metalboy-testrom /path/to/instr_timing.gb --frames 1800` | `Passed` |
| blargg mem_timing(01/02/03) | `metalboy-testrom /path/to/mem_timing/01.gb --frames 900` | `Passed` |
| blargg halt_bug(参考) | `metalboy-testrom /path/to/halt_bug.gb --frames 1800` | `Passed` |

- 合格率は **100%**(SC-007 の基準)
- blargg 系 ROM は各サブテストごとに独立した ROM を実行する
- 不合格の場合、シリアル出力に失敗理由(`Failed #NN` 等)が出るため
  該当コア実装を修正する

## 実装メモ

- 現実装は研究 R-6 の簡易化(simple CPU/PPU/APU/TIMER 体制)を取るため、
  本スイート一覧は MBC 動作・シリアル経路の最低合格ラインを基準にする
- RTC 簡易対応のため、MBC3 + RTC を含むスイートは簡易動作のみ検証対象外

## Mooneye テストスイート(acceptance 75 本)

精密度の主要指標。コミットメッセージ末尾の `(Mooneye N/75)` はこのスイートの PASS 数。

判定は専用ツール `metalboy-mooneye`(`Sources/Tools/Mooneye/main.m`)で行う。
`metalboy-testrom` は結果のバイト列を判定できないため使わない。

### ROM の入手

`Gekkio/mooneye-test-suite` をソースからビルドする(要 `brew install wla-dx`)。

```sh
git clone https://github.com/Gekkio/mooneye-test-suite /tmp/mts-src
make -C /tmp/mts-src        # → /tmp/mts-src/build/acceptance/**/*.gb
```

prebuilt 版(`https://gekkio.fi/files/mooneye-test-suite/`、検証時は mts-20260714-0944-31510e1)でもよい。

### ビルドと実行

```sh
cd MetalBoy
xcodebuild -project MetalBoy.xcodeproj -scheme metalboy-mooneye build
M=Build/Products/Debug/metalboy-mooneye
$M <rom.gb> [--bios <path>] [--seconds N]   # 既定 15 秒(実時間)で打切り
# 全件
find /tmp/mts-src/build/acceptance -name '*.gb' | sort | \
  while read r; do $M "$r"; done | tee /tmp/mooneye_results.txt
grep -c '^PASS' /tmp/mooneye_results.txt
```

- 判定はシリアル quit プロトコル: `03 05 08 0D 15 22`(Fibonacci)= `PASS`(終了コード 0)、
  `42`×6 = `FAIL`(1)、時間内にどちらも来なければ `TIMEOUT`(2, レジスタ・IO・PPU 状態を併記)
- 修正前後で結果ファイルを `diff` し、FAIL 集合が増えていないこと(リグレッションなし)を確認する
- `boot_*` 系は電源投入時の状態を見るため BIOS の有無で結果が変わる。`--bios` で
  実 DMG BIOS を `gb.bootROMData` に供給して起動できる。
  `boot_regs-dmg0` は BIOS 供給時のみ PASS が正しい
- 現状の PASS 数と未通過の内訳は `docs/core-fidelity-notes.md` の「Mooneye 結果」節を参照
