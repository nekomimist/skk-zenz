# 変更履歴

## 未リリース

### 追加

- `zenz-server`: llama.cpp で zenz v3.2 を読み込み、前後の文脈を使って読みを変換する。標準入出力で JSON Lines のプロトコル（バージョン 2）を提供する。単発で変換する `--convert` と、プロンプトを表示する `--prompt` も使える。
- `zenz-server`: 与えた候補それぞれに、文脈を踏まえた対数尤度を付ける `score` 操作を追加した。`--convert` と `--score` を組み合わせると単発でも試せる。
- ビーム探索で複数の候補を出す。プロンプトの計算結果（KV キャッシュ）はビーム間で共有する。
- `skk-zenz.el`: `skk-zenz-mode` で zenz を `skk-search-prog-list` に追加する。長い読みは辞書より先に、それ以外は辞書の候補のあとに zenz を使う。長い読みで確定した語は個人辞書に登録しない。それ以外の語は zenz の注釈を外して学習する（`skk-zenz-learn-fallback`）。
- `make model` でモデルをダウンロードし、SHA-256 を検証する。
- `skk-zenz.el`: `skk-zenz-rerank` を有効にすると、辞書の候補を文脈に合わせて zenz で並べ替える（既定では無効）。`skk-zenz-mode` は辞書検索をまとめて `skk-zenz-rerank-search` に置き換え、モードを無効にすると元に戻す。送りありの読みも、語幹に送り仮名を付けた形で採点して並べ替える。
- `skk-zenz.el`: 左の文脈を集めるとき、かなや漢字を含まない行を飛ばし、その上の文章を使う（`skk-zenz-context-skip-non-japanese`）。Org の src ブロックやコードの中の日本語コメントで、文脈がコードで埋まらなくなる。
- `scripts/eval_rerank.py`: 手元の文章と SKK 辞書を使って、並べ替えの効果を評価する。
- `scripts/eval_convert.py`: 手元の文章や AJIMEE-Bench を使って、文脈の長さ、候補の数、読みの長さごとに変換の精度を評価する。
- `zenz-server`: `--max-context` で、前後の文脈を何文字まで使うかを変えられる（既定は 40 文字）。
