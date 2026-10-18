# テスト ROM(標準テストスイート一覧)

SC-007(テスト ROM の合格)で使用するスイートと合格基準の一覧。
本リポジトリは ROM を同梱・配布しない(restore: 入手はユーザー側で行う)。

## ROM パスの指定方式

テスト ROM は **外部パス指定のみ**。リポジトリ内に置かない
(`.gitignore` の `*.gb` / `*.gbc` 除外ポリシー)。

```sh
# 実行形式(ランナーは Sources/Tools/main.m・ターゲット metalboy-testrom)
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
