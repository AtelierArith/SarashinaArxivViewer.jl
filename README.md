# SarashinaArxivViewer.jl

[Sarashina.jl](../Sarashina.jl) と [PDFIO.jl](https://github.com/sambitdash/PDFIO.jl) で作った arXiv RAG 解説ボット
([sarashina-arxiv-rag](https://github.com/terasakisatoshi/sarashina-arxiv-rag) の `sarashina-web` の Julia 版)。

```sh
# API キーは環境変数 SARASHINA_API_KEY、またはカレントの .env
julia --project=. -e 'using SarashinaArxivViewer; serve()'   # http://127.0.0.1:8000
julia --project=. test/runtests.jl                            # オフラインテスト(モック API)
```

流れ: arXiv URL → PDF 取得 → PDFIO で段落抽出 → `sarashina3-embedding` で索引 →
質問を英訳 → `RETRIEVAL_QUERY` 埋め込み + コサイン top-20 → `sarashina3-rerank` top-5 →
`sarashina3.2-mini-thinking` が日本語で SSE 回答(参考ページ付き)。左ペインの段落クリックで
`sarashina3.2-translate` による日本語訳。API は元実装と同じ(`/api/index`, `/api/paper`,
`/api/translate`, `/api/chat`, `/api/suggest`)。キャッシュは `~/.cache/sarashina-client`
(`SARASHINA_CACHE_DIR` で変更可、JSON 形式)。

元実装との差: 回答モデルを提供終了予定の `sarashina3-mini` から `sarashina3.2-mini-thinking` に変更。
RPM 制限はスライディング窓で管理(embedding 55/分, translate・chat 25/分 など)。
Sarashina.jl は `Project.toml` の `[sources]` で GitHub の URL から取得します(`Pkg.instantiate()`)。

## フローチャート

Mermaid なので GitHub / VS Code のプレビューでそのまま描画されます。

### 索引構築(`run_index!`)

```mermaid
flowchart TD
    A["POST /api/index<br/>server.jl:55"] --> B["Job 作成<br/>@async run_index!"]
    B --> C["normalize_url<br/>abs → pdf"]
    C --> D["make_key / doc_key<br/>cache.jl:26-36"]
    D --> E{"load_index<br/>索引キャッシュあり?"}
    E -- あり --> F["apply_cached!<br/>seed_embeddings"]
    F --> Z1(["status=done<br/>cached=true"])
    E -- なし --> G["download_pdf<br/>pdf.jl:28"]
    G --> H["extract_blocks<br/>PDFIO → 段落"]
    H --> I{"抽出テキスト<br/>ある?"}
    I -- なし --> ZE(["status=error<br/>scanned PDF"])
    I -- あり --> J["split_text<br/>4800文字上限でチャンク化"]
    J --> K["load_embeddings<br/>text_hash で照合"]
    K --> L{"全チャンク<br/>キャッシュ済み?"}
    L -- 一部ヒット --> M["ヒット分は再利用<br/>reused を加算"]
    L -- ミスあり --> N["embed_many<br/>RETRIEVAL_DOCUMENT<br/>最大4並列<br/>rag.jl:55"]
    M --> N
    N --> O["save_embeddings<br/>save_index<br/>indexing.jl:129-134"]
    O --> Z2(["status=done<br/>indexed=true"])
```

### 質問応答(`api_chat` + `retrieve`)

```mermaid
flowchart TD
    A["POST /api/chat<br/>server.jl:112"] --> B{"job.indexed?"}
    B -- いいえ --> BE(["409 RAG index not built"])
    B -- はい --> C["translate<br/>ja → en<br/>(RateLimiter 25/分)"]
    C --> D["embed_text<br/>RETRIEVAL_QUERY"]
    D --> E["コサイン類似度<br/>全チャンク総当たり<br/>rag.jl:70"]
    E --> F["sortperm で top-20"]
    F --> G{"チャンク空?"}
    G -- 空 --> H["indices = Int[]"]
    G -- あり --> I["rerank GENERAL_QA<br/>top-5 に再順位付け<br/>rag.jl:88"]
    H --> J
    I --> J["build_context<br/>[p.N] 付き抜粋"]
    J --> K["messages に system(context)<br/>と user(質問) を push"]
    K --> L["chat_stream<br/>sarashina3.2-mini-thinking"]
    L --> M["SSE: data delta"]
    M --> N["assistant 応答を履歴に保存"]
    N --> O["SSE: 参考ページ p.N リンク"]
    O --> P["SSE: [DONE]"]
```

### キャッシュのキーと読み書き

```mermaid
flowchart LR
    subgraph 入力
        U["arXiv URL"]
        P["pages 例 1-3"]
    end
    U --> ID["arxiv_id<br/>1706.03762"]
    U --> URLR["arXiv 以外<br/>url-先頭16文字"]
    ID --> DK["doc_key<br/>arxiv-1706.03762"]
    URLR --> DK
    DK --> IK["make_key<br/>doc_key__pages-all"]
    P --> IK
    DK --> EF["__embeddings.json<br/>hash → vector"]
    DK --> TF["__translations.json<br/>hash → 日本語訳"]
    IK --> IF["__pages-all.json<br/>title/chunks/pages/vectors"]
    EF --> DIR["SARASHINA_CACHE_DIR<br/>既定 ~/.cache/sarashina-client"]
    TF --> DIR
    IF --> DIR
```

補足:

- 索引構築は `@async` で走るので、UI は `/api/index/{id}` をポーリングして `phase`(`extracting` → `embedding` → `done`)を表示する。
- 左ペインの段落クリックは上のチャットフローとは別に `/api/translate` を通る(`translate_chunk!`、既訳ならキャッシュから返り API を呼ばない)。
