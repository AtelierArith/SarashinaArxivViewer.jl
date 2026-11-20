using Test
using HTTP
using JSON
using Sarashina
using SarashinaArxivViewer
const SAV = SarashinaArxivViewer

ENV["SARASHINA_CACHE_DIR"] = mktempdir()

# 2 ページの最小 PDF(各ページに 2 段落)。xref テーブルを正しく付ける(PDFIO は再構築しない)。
function tiny_pdf()
    page(lines) = "BT /F1 12 Tf 72 720 Td 14 TL " * join(("($l) Tj T*" for l in lines), " ") * " ET"
    streams = [page(["Attention is all you need.", "We propose the Transformer."]),
               page(["Results are strong.", "BLEU 28.4 on WMT."])]
    objs = String[]
    push!(objs, "<< /Type /Catalog /Pages 2 0 R >>")
    push!(objs, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
    for k in eachindex(streams)
        push!(objs, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $(4 + k) 0 R /Resources << /Font << /F1 7 0 R >> >> >>")
    end
    for st in streams
        push!(objs, "<< /Length $(length(st)) >>\nstream\n$st\nendstream")
    end
    push!(objs, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    io = IOBuffer(); write(io, "%PDF-1.4\n")
    offsets = Int[]
    for (i, o) in enumerate(objs)
        push!(offsets, position(io))
        write(io, "$i 0 obj\n$o\nendobj\n")
    end
    xref = position(io)
    write(io, "xref\n0 $(length(objs) + 1)\n0000000000 65535 f \n")
    for off in offsets
        write(io, lpad(off, 10, '0'), " 00000 n \n")
    end
    write(io, "trailer\n<< /Root 1 0 R /Size $(length(objs) + 1) >>\nstartxref\n$xref\n%%EOF\n")
    return take!(io)
end

@testset "cache keys" begin
    @test SAV.arxiv_id("https://arxiv.org/abs/1706.03762") == "1706.03762"
    @test SAV.arxiv_id("https://arxiv.org/pdf/1706.03762.pdf") == "1706.03762"
    @test SAV.arxiv_id("https://example.com/pdf/1.pdf") === nothing
    @test SAV.make_key("https://arxiv.org/pdf/1706.03762", "1-3") == "arxiv-1706.03762__pages-1-3"
    @test SAV.make_key("https://arxiv.org/pdf/1706.03762", nothing) == "arxiv-1706.03762__pages-all"
    @test startswith(SAV.doc_key("https://example.com/a.pdf"), "url-")
end

@testset "pdf helpers" begin
    @test SAV.normalize_url("https://arxiv.org/abs/1706.03762") == "https://arxiv.org/pdf/1706.03762"
    @test SAV.parse_pages("1-3") == (1, 3)
    @test SAV.parse_pages("2") == (2, 2)
    @test_throws ArgumentError SAV.parse_pages("3-1")
    @test_throws ArgumentError SAV.parse_pages("abc")
    @test SAV.split_text("  ") == String[]
    @test SAV.split_text("abc") == ["abc"]
    parts = SAV.split_text(repeat("あ", 25), 10)
    @test all(length(p) <= 10 for p in parts) && join(parts) == repeat("あ", 25)
    txt = "  Intro\n\n  This is a long line of text that fills the whole width of a column of the page\n  and ends short.\n  Next paragraph starts with multi-\n  plex words here and continues on and on to fill the width of the column.\n"
    @test SAV.paragraphs(txt) == ["Intro",
        "This is a long line of text that fills the whole width of a column of the page and ends short.",
        "Next paragraph starts with multiplex words here and continues on and on to fill the width of the column."]
end

@testset "rate limiter / cosine" begin
    rl = SAV.RateLimiter(2, 0.3)
    t = @elapsed for _ in 1:3; SAV.acquire!(rl); end
    @test t >= 0.25
    @test SAV.cosine([1, 0], [1, 0]) ≈ 1
    @test SAV.cosine([1, 0], [0, 1]) ≈ 0
    @test SAV.cosine([0, 0], [1, 1]) == 0
end

# ---- モック Sarashina API + PDF 配信 ----
const SEEN = Any[]
function mock(http::HTTP.Stream)
    req = http.message
    body = String(read(http))
    path = String(HTTP.URI(req.target).path)
    obj = isempty(body) ? Dict{String,Any}() : JSON.parse(body; dicttype = Dict{String,Any})
    push!(SEEN, (path, obj))
    function reply(status, ctype, data)
        HTTP.setstatus(http, status); HTTP.setheader(http, "Content-Type" => ctype)
        HTTP.setheader(http, "Content-Length" => string(sizeof(data)))
        HTTP.startwrite(http); write(http, data)
    end
    if path == "/pdf/9999.99999"
        reply(200, "application/pdf", tiny_pdf())
    elseif path == "/v1/embeddings"
        v = occursin("Transformer", obj["input"]) ? [1.0, 0.0, 0.0] : [0.0, 1.0, 0.0]
        obj["task_type"] == "RETRIEVAL_QUERY" && (v = [1.0, 0.0, 0.0])
        reply(200, "application/json", JSON.json(Dict("data" => [Dict("embedding" => v)])))
    elseif path == "/v1/rerank"
        n = length(obj["documents"])
        res = [Dict("document_id" => i - 1, "score" => 1.0 / i) for i in 1:n]
        reply(200, "application/json", JSON.json(Dict("data" => [Dict("result" => res)])))
    elseif path == "/v1/translate"
        out = obj["target_lang"] == "en" ? "What is the Transformer?" : "訳: " * obj["text"]
        reply(200, "application/json", JSON.json(Dict("translated_text" => out)))
    elseif path == "/v1/chat/completions"
        if get(obj, "stream", false) == true
            HTTP.setstatus(http, 200); HTTP.setheader(http, "Content-Type" => "text/event-stream")
            HTTP.startwrite(http)
            for t in ("Transformer", "です")
                write(http, "data: " * JSON.json(Dict("choices" => [Dict("delta" => Dict("content" => t))])) * "\n\n")
            end
            write(http, "data: [DONE]\n\n")
        else
            reply(200, "application/json", JSON.json(Dict("choices" => [Dict("message" =>
                Dict("content" => "- 質問A\n2. 質問B\n質問C\n質問D"))])))
        end
    else
        reply(404, "application/json", JSON.json(Dict("message" => "nope")))
    end
end

api = HTTP.listen!(mock, "127.0.0.1", 0; listenany = true)
api_url = "http://127.0.0.1:$(HTTP.port(api))"
client = Sarashina.Client(api_key = "test", base_url = api_url)
app = SarashinaArxivViewer.serve(; port = 0, client, wait = false)
base = "http://127.0.0.1:$(HTTP.port(app))"

post(path, obj) = HTTP.post(base * path, ["Content-Type" => "application/json"], JSON.json(obj); status_exception = false)
getj(path) = HTTP.get(base * path; status_exception = false)
parsej(r) = JSON.parse(String(r.body); dicttype = Dict{String,Any})

@testset "web app" begin
    r = getj("/")
    @test r.status == 200 && occursin("arXiv RAG", String(r.body))

    @test post("/api/index", Dict("url" => "ftp://x")).status == 400
    @test post("/api/index", Dict("url" => api_url * "/pdf/9999.99999", "pages" => "x")).status == 400
    @test getj("/api/index/nope").status == 404

    r = post("/api/index", Dict("url" => api_url * "/pdf/9999.99999", "pages" => "1-2"))
    @test r.status == 200
    id = parsej(r)["job_id"]
    local info
    for _ in 1:100
        info = parsej(getj("/api/index/$id"))
        info["status"] == "running" || break
        sleep(0.1)
    end
    @test info["status"] == "done"
    @test info["indexed"] && info["embed_total"] == info["embed_done"] > 0

    paper = parsej(getj("/api/paper/$id"))
    @test length(paper["chunks"]) == 2
    @test sort(unique(c["page"] for c in paper["chunks"])) == [1, 2]
    @test any(occursin("Transformer", c["text"]) for c in paper["chunks"])
    @test isempty(paper["translations"])

    # 翻訳: 初回は API、2 回目はキャッシュ
    n0 = count(s -> s[1] == "/v1/translate", SEEN)
    t1 = parsej(post("/api/translate", Dict("job_id" => id, "index" => 0)))
    @test startswith(t1["text"], "訳: ")
    t2 = parsej(post("/api/translate", Dict("job_id" => id, "index" => 0)))
    @test t2["text"] == t1["text"]
    @test count(s -> s[1] == "/v1/translate", SEEN) == n0 + 1
    @test post("/api/translate", Dict("job_id" => id, "index" => 99)).status == 400
    @test haskey(parsej(getj("/api/paper/$id"))["translations"], "0")

    # チャット(SSE)
    r = post("/api/chat", Dict("job_id" => id, "message" => "Transformer とは?"))
    @test r.status == 200
    sse_text = String(r.body)   # String(::Vector) は本文を空にするので 1 回だけ
    events = [JSON.parse(strip(l)[7:end]) for l in split(sse_text, "\n\n") if startswith(strip(l), "data: {")]
    @test join(get(e, "delta", "") for e in events) == "Transformerです"
    @test any(haskey(e, "note") && occursin("#page-1", e["note"]) for e in events)
    @test occursin("data: [DONE]", sse_text)
    q = filter(s -> s[1] == "/v1/embeddings" && s[2]["task_type"] == "RETRIEVAL_QUERY", SEEN)
    @test q[end][2]["input"] == "What is the Transformer?"      # 英訳した質問で検索
    chat_req = last(filter(s -> s[1] == "/v1/chat/completions", SEEN))[2]
    msgs = chat_req["messages"]
    @test msgs[1]["role"] == "system" && occursin("[p.", msgs[2]["content"]) && msgs[end]["role"] == "user"

    # 次の質問候補
    sug = parsej(post("/api/suggest", Dict("job_id" => id)))["suggestions"]
    @test sug == ["質問A", "質問B", "質問C"]

    # 再構築は索引キャッシュから(埋め込みを呼ばない)
    ne = count(s -> s[1] == "/v1/embeddings", SEEN)
    id2 = parsej(post("/api/index", Dict("url" => api_url * "/pdf/9999.99999", "pages" => "1-2")))["job_id"]
    sleep(0.5)
    info2 = parsej(getj("/api/index/$id2"))
    @test info2["status"] == "done" && info2["cached"]
    @test count(s -> s[1] == "/v1/embeddings", SEEN) == ne

    @test post("/api/chat", Dict("job_id" => id)).status == 422
    @test getj("/nope").status == 404
end

close(app); close(api)
