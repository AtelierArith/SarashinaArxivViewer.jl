# AGENTS.md

SarashinaArxivViewer.jl は arXiv 論文の RAG 解説ボット(Web アプリ)。Sarashina.jl(Sarashina API クライアント)と PDFIO.jl を使う。

## 依存の取得: `JULIA_PKG_USE_CLI_GIT=true` が必要

Sarashina.jl は **private リポジトリ**(`AtelierArith/Sarashina.jl`)で、`Project.toml` の `[sources]` に SSH URL で指定している。

```toml
[sources]
Sarashina = {rev = "main", url = "git@github.com:AtelierArith/Sarashina.jl.git"}
```

Julia 組み込みの libgit2 は SSH 鍵(ssh-agent / `~/.ssh/config`)を見つけられず、`Private key location for 'git@github.com': ... user cancelled credential request` で失敗する。HTTPS URL も private のため認証が通らない。`git` CLI を使わせると解決する。

```sh
JULIA_PKG_USE_CLI_GIT=true julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

- `Pkg.add` / `Pkg.update` / `Pkg.instantiate` / `Pkg.resolve` など、Sarashina.jl を clone/fetch しうる操作は全て同じ環境変数を付ける。
- 一度取得すれば `~/.julia` にキャッシュされるため、通常の `using` やテスト実行には不要。
- `Manifest.toml` は git 管理外(マシン固有のため)。

## 開発

- 起動: `julia --project=. -e 'using SarashinaArxivViewer; serve()'`
- テスト: `julia --project=. test/runtests.jl`(モック API + 最小 PDF。キー・ネットワーク不要)
- API キー: `SARASHINA_API_KEY`(環境変数またはカレントの `.env`)。`.env` の中身は読まない・出力しない。
- HTTP.jl は 2.x。ストリーミング応答のサーバーは `HTTP.serve!(...; stream=true)` ではなく `HTTP.listen!` を使う。
- PDFIO は xref を再構築しない。テスト用 PDF には正しい xref テーブルが必要(`test/runtests.jl` の `tiny_pdf`)。
- `String(r.body)` は `Vector{UInt8}` を空にする。本文は 1 回だけ文字列化して使い回す。
- Sarashina API の RPM 制限は `src/rag.jl` の `RateLimiter` で守る。仕様は Sarashina.jl 側の AGENTS.md を参照。
