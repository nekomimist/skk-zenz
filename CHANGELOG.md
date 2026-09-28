# 変更履歴

## 未リリース

### 追加

- `zenz-server`: llama.cpp で zenz v3.2 を読み込み、前後の文脈を使って読みを変換する。標準入出力で JSON Lines のプロトコル（バージョン 2）を提供する。単発で変換する `--convert` と、プロンプトを表示する `--prompt` も使える。
- `zenz-server`: 与えた候補それぞれに、文脈を踏まえた対数尤度を付ける `score` 操作を追加した。`--convert` と `--score` を組み合わせると単発でも試せる。
- ビーム探索で複数の候補を出す。プロンプトの計算結果（KV キャッシュ）はビーム間で共有する。
- `skk-zenz.el`: `skk-zenz-mode` で zenz を `skk-search-prog-list` に追加する。長い読みは辞書より先に、それ以外は辞書の候補のあとに zenz を使う。長い読みで確定した語は個人辞書に登録しない。それ以外の語は zenz の注釈を外して学習する（`skk-zenz-learn-fallback`）。
- `make model` でモデルをダウンロードし、SHA-256 を検証する。
