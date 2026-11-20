# AGENTS.md

SarashinaArxivViewer.jl は arXiv 論文の RAG 解説ボット(Web アプリ)。Sarashina.jl(Sarashina API クライアント)と PDFIO.jl を使う。

## 依存: Sarashina.jl

Sarashina.jl(public リポジトリ `AtelierArith/Sarashina.jl`)は `Project.toml` の `[sources]` に HTTPS URL で指定している。通常の `Pkg.instantiate()` だけで取得でき、特別な環境変数は要らない。

```toml
[sources]
Sarashina = {rev = "main", url = "https://github.com/AtelierArith/Sarashina.jl"}
```

- `Manifest.toml` は git 管理外(マシン固有のため)。
- 以前は private で SSH URL + `JULIA_PKG_USE_CLI_GIT=true` が必要だったが、public 化により不要になった。

## 開発

- 起動: `julia --project=. -e 'using SarashinaArxivViewer; serve()'`
- テスト: `julia --project=. test/runtests.jl`(モック API + 最小 PDF。キー・ネットワーク不要)
- API キー: `SARASHINA_API_KEY`(環境変数またはカレントの `.env`)。`.env` の中身は読まない・出力しない。
- HTTP.jl は 2.x。ストリーミング応答のサーバーは `HTTP.serve!(...; stream=true)` ではなく `HTTP.listen!` を使う。
- PDFIO は xref を再構築しない。テスト用 PDF には正しい xref テーブルが必要(`test/runtests.jl` の `tiny_pdf`)。
- `String(r.body)` は `Vector{UInt8}` を空にする。本文は 1 回だけ文字列化して使い回す。
- Sarashina API の RPM 制限は `src/rag.jl` の `RateLimiter` で守る。仕様は Sarashina.jl 側の AGENTS.md を参照。
