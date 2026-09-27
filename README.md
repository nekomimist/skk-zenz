# skk-zenz

[DDSKK](https://github.com/skk-dev/ddskk) に、言語モデル
[zenz v3.2](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) によるかな漢字変換を追加します。
モデルは [llama.cpp](https://github.com/azooKey/llama.cpp) を使って手元の CPU で動くため、
入力した文章は外部に送られず、API の利用料もかかりません。

- 長い読み（既定では 10 文字以上）は、辞書より先に zenz で変換します。
- それ以外の読みでは、辞書の候補を出し尽くしたあとに zenz の候補を出します。辞書登録モードに入るのは、その候補も尽きたときです。
- zenz は変換対象の前後の文章を文脈として使います。同じ読みでも文脈によって変換結果が変わります（試験問題の**解答**、電子レンジで**解凍**）。
- 長い読みで zenz の候補を確定しても、個人辞書には登録しません。それ以外で zenz の候補を確定したときは、辞書の候補と同じように個人辞書に学習します。

開発中のソフトウェアです。動作確認は Linux x86_64 上の Emacs 29.4 と 31.1 で行っています。

## 必要なもの

- Linux x86_64（ARM64 は対応予定）
- CMake 3.16 以降と C++17 コンパイラ
- Emacs 29.1 以降と DDSKK
- git と curl
- サーバ用のメモリ約 100 MB

## ビルド

```sh
git clone --recurse-submodules --shallow-submodules <repository-url> skk-zenz
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

### 設定項目

| 変数 | 既定値 | 意味 |
|---|---|---|
| `skk-zenz-min-length` | `10` | この文字数以上の読みは、辞書より先に zenz で変換する。`nil` にすると、zenz は辞書の候補のあとにだけ使う。 |
| `skk-zenz-long-candidates` | `3` | 長い読みで zenz に求める候補の数。 |
| `skk-zenz-fallback-candidates` | `5` | 辞書の候補のあとに zenz に求める候補の数。 |
| `skk-zenz-context-length` | `40` | 文脈として前後それぞれに送る最大文字数。`0` にすると文脈を送らない。 |
| `skk-zenz-annotation` | `"zenz"` | zenz の候補に付ける注釈。`nil` にすると注釈を付けない。 |
| `skk-zenz-learn-fallback` | `t` | 辞書の候補のあとに出した zenz の候補を確定したとき、個人辞書に学習するかどうか。 |
| `skk-zenz-timeout` | `1.0` | 変換結果を待つ秒数。 |
| `skk-zenz-server-args` | `nil` | サーバに渡す追加の引数。例: `("--threads" "8")` |
| `skk-zenz-reading-regexp` | ひらがな・ー・、。・！？ | zenz に送る読みを表す正規表現。 |

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

サーバの応答時間は `scripts/bench_server.py` で計測できます。設計は
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、今後の計画は [docs/ROADMAP.md](docs/ROADMAP.md) にあります（どちらも英語）。

## ライセンス

MIT License です。[LICENSE](LICENSE) を参照してください。

## 利用しているもの

- llama.cpp（[azooKey のフォーク](https://github.com/azooKey/llama.cpp)、ブランチ `azookey/b9637-compat`）: MIT License。本家の llama.cpp は zenz のトークナイザを読み込めないため、フォークが必要です。
- Miwa-Keita 氏の zenz-v3.2-small モデル: Apache License 2.0。このリポジトリには含めていません。`make model` でダウンロードします。
- プロンプトの形式と前処理は [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) に従っています。AzooKeyKanaKanjiConverter は MIT License です（Copyright (c) 2023 Miwa / Ensan）。
