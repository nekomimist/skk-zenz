# skk-zenz

[DDSKK](https://github.com/skk-dev/ddskk) に、言語モデル
[zenz v3.2](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) によるかな漢字変換を追加します。
モデルは [llama.cpp](https://github.com/azooKey/llama.cpp) を使って手元の CPU で動くため、
入力した文章は外部に送られず、API の利用料もかかりません。

- 長い読み（既定では 10 文字以上）は、辞書より先に zenz で変換します。
- それ以外の読みでは、辞書の候補を出し尽くしたあとに zenz の候補を出します。辞書登録モードに入るのは、その候補も尽きたときです。
- zenz は変換対象の前後の文章を文脈として使います。同じ読みでも文脈によって変換結果が変わります（試験問題の**解答**、電子レンジで**解凍**）。
- 長い読みで zenz の候補を確定しても、個人辞書には登録しません。それ以外で zenz の候補を確定したときは、辞書の候補と同じように個人辞書に学習します。
- zenz で辞書の候補を並べ替え、文脈に合うものを先に出すこともできます（`skk-zenz-rerank`、既定では無効）。

開発中のソフトウェアです。動作確認は Linux x86_64 上の Emacs 29.4 と 31.1 で行っています。

## 必要なもの

- Linux x86_64（ARM64 は対応予定）
- CMake 3.16 以降と C++17 コンパイラ
- Emacs 29.1 以降と DDSKK
- git と curl
- サーバ用のメモリ約 100 MB

## ビルド

```sh
git clone --recurse-submodules --shallow-submodules https://github.com/nekomimist/skk-zenz.git
cd skk-zenz
make build   # build/zenz-server をビルドする
make model   # モデル（70 MB）を models/ にダウンロードし、SHA-256 を検証する
```

`--recurse-submodules` を付けずに clone した場合は、先に
`git submodule update --init --depth 1` を実行してください。

コマンドラインでサーバの動作を確認できます。

```sh
$ build/zenz-server --model models/zenz-v3.2-small-Q5_K_M.gguf \
    --convert かいとう --left 試験問題の -n 3
解答
回答
解凍
```

## Emacs の設定

```elisp
(add-to-list 'load-path "/path/to/skk-zenz")
(require 'skk-zenz)
(skk-zenz-mode 1)
```

`skk-zenz-mode` は、`skk-search-prog-list` を設定したあとで有効にしてください。
有効にすると、リストの先頭に `(skk-zenz-search :long)` を、末尾に
`(skk-zenz-search :fallback)` を追加します。無効にすると、この 2 つを取り除いてサーバを止めます。

skk-zenz をこのディレクトリから読み込むと、サーバとモデルを自動で見つけます。
対象は `build/zenz-server` と `models/zenz-v3.2-small-Q5_K_M.gguf` です。別の場所に置いた場合は、
`skk-zenz-server-program` と `skk-zenz-model-file`（または環境変数 `ZENZ_MODEL`）を設定してください。

### 辞書の候補の並べ替え

`skk-zenz-rerank` を `t` にしてから `skk-zenz-mode` を有効にすると、辞書の候補を文脈に合わせて並べ替えます。

```elisp
(setq skk-zenz-rerank t)
(skk-zenz-mode 1)
```

`skk-zenz-mode` は、`skk-search-prog-list` のうち最初に連続して並ぶ辞書検索をまとめます。
まとめた部分は 1 つの `(skk-zenz-rerank-search '(...))` になります。対象になる検索関数は `skk-zenz-rerank-programs` で決まります。
まとめた辞書は一度にすべて引き、候補を重複なく合わせてから、zenz が求めた「この文脈でこの表記になる確率」で並べ替えます。
モードを無効にすると、元の辞書検索に戻します。
`skk-search-prog-list` に `skk-zenz-rerank-search` を自分で書いてもかまいません。この場合、モードはリストを書き換えません。

- 既定の `promote` は、zenz のスコアが最も高い候補を先頭に移します。ただし、そのスコアが先頭の候補を `skk-zenz-rerank-threshold` より大きく上回るときだけです。ほかの候補は辞書の順のままです。
- `mix` は、zenz のスコアから辞書での順位の分（`skk-zenz-rerank-weight` × log(1 + 順位)）を引いた値で、すべての候補を並べ替えます。
- 個人辞書の学習はこれまでどおりです。最後に確定した語は辞書の先頭に来るので、並べ替えのときにも優先されます。
- 送りありの読みも並べ替えます。語幹に送り仮名を付けた形（「書く」「描く」）で採点するので、「手紙を」のあとなら「書く」、「絵を」のあとなら「描く」が先頭に来ます。
- zenz が応答しないときや時間切れのときは、辞書の順のまま候補を出します。

同じ読みの候補が複数ある語で試すと、先頭の候補の正解率は 89.4% から 98.6% に上がりました（作者のブログ記事で評価）。
並べ替えにかかる時間は、候補 20 個で約 40 ms です。

### 設定項目

| 変数 | 既定値 | 意味 |
|---|---|---|
| `skk-zenz-min-length` | `10` | この文字数以上の読みは、辞書より先に zenz で変換する。`nil` にすると、zenz は辞書の候補のあとにだけ使う。 |
| `skk-zenz-long-candidates` | `5` | 長い読みで zenz に求める候補の数。 |
| `skk-zenz-fallback-candidates` | `5` | 辞書の候補のあとに zenz に求める候補の数。 |
| `skk-zenz-context-length` | `40` | 文脈として前後それぞれに送る最大文字数。`0` にすると文脈を送らない。 |
| `skk-zenz-context-skip-non-japanese` | `t` | 左の文脈を集めるとき、かなや漢字を含まない行（コードなど）を飛ばし、さらに上の行から拾う。変換する行は常に使う。`nil` にすると、変換位置の直前の文字をそのまま送る。 |
| `skk-zenz-annotation` | `"zenz"` | zenz の候補に付ける注釈。`nil` にすると注釈を付けない。 |
| `skk-zenz-learn-fallback` | `t` | 辞書の候補のあとに出した zenz の候補を確定したとき、個人辞書に学習するかどうか。 |
| `skk-zenz-timeout` | `1.0` | 変換結果を待つ秒数。 |
| `skk-zenz-server-args` | `nil` | サーバに渡す追加の引数。例: `("--threads" "8")` |
| `skk-zenz-reading-regexp` | ひらがな・ー・、。・！？ | zenz に送る読みを表す正規表現。 |
| `skk-zenz-rerank` | `nil` | `t` なら、`skk-zenz-mode` が辞書の候補を zenz で並べ替える。設定はモードの有効化より前に行う。 |
| `skk-zenz-rerank-method` | `promote` | 並べ替えの方法。`promote` または `mix`。 |
| `skk-zenz-rerank-threshold` | `1.0` | `promote` で候補を先頭へ移すための、スコアの差（対数確率）の下限。大きくすると先頭が変わりにくくなる。 |
| `skk-zenz-rerank-weight` | `1.0` | `mix` で、辞書での順位をどれだけ重視するか。 |
| `skk-zenz-rerank-limit` | `20` | zenz で採点する、先頭からの候補の数。 |
| `skk-zenz-rerank-timeout` | `0.3` | 採点を待つ秒数。過ぎたら辞書の順のまま出す。 |

最近の x86_64 CPU で 4 スレッドを使う場合、変換にかかる時間は短い読みで約 20 ms、20 文字程度の読みで 60〜130 ms です。
候補の数を増やすほど時間がかかります。

### うまく動かないとき

- サーバの問題はエコーエリアに表示されます。失敗したあとは、`skk-zenz-retry-interval`（30 秒）が過ぎるまでサーバを再起動しません。すぐに再起動するには `M-x skk-zenz-restart` を実行してください。
- サーバの標準エラー出力は、バッファ ` *zenz-server stderr*` で確認できます。
- `skk-zenz-debug` を `t` にすると、サーバとのやりとりを `*Messages*` に記録します。

## 開発

```sh
make test
```

`make test` は、サーバのビルド、C++ のテスト、`skk-zenz.el` のバイトコンパイル、ERT のテストを順に実行します。
初回は DDSKK を `build/deps/ddskk` に clone します。インストール済みの DDSKK を使うには `DDSKK_DIR` を指定してください。
モデルが必要なテストは、モデルファイルがあるときだけ実行し、ないときはスキップします。
モデルファイルは `models/zenz-v3.2-small-Q5_K_M.gguf`、または `ZENZ_MODEL` が指すファイルです。

サーバの応答時間は `scripts/bench_server.py` で計測できます。
候補の並べ替えの効果は `scripts/eval_rerank.py` で評価できます。
変換の精度と、設定値（文脈の長さ、候補の数、`skk-zenz-min-length`）による違いは `scripts/eval_convert.py` で評価できます。
使い方はそれぞれのスクリプトの先頭を参照してください（`uv` が必要）。設計は
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、今後の計画は [docs/ROADMAP.md](docs/ROADMAP.md) にあります（どちらも英語）。

## ライセンス

MIT License です。[LICENSE](LICENSE) を参照してください。

## 利用しているもの

- llama.cpp（[azooKey のフォーク](https://github.com/azooKey/llama.cpp)、ブランチ `azookey/b9637-compat`）: MIT License。本家の llama.cpp は zenz のトークナイザを読み込めないため、フォークが必要です。
- Miwa-Keita 氏の zenz-v3.2-small モデル: Apache License 2.0。このリポジトリには含めていません。`make model` でダウンロードします。
- プロンプトの形式と前処理は [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) に従っています。AzooKeyKanaKanjiConverter は MIT License です（Copyright (c) 2023 Miwa / Ensan）。
