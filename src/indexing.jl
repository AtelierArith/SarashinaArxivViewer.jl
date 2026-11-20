# インデックス構築ジョブ(PDF 取得 → 抽出 → 埋め込み)と会話状態。

const CHAT_MODEL = Sarashina.MODELS.mini_thinking
const SUGGEST_MODEL = Sarashina.MODELS.nano

const INSTRUCTIONS = "あなたは論文の解説アシスタントです。ユーザーの質問ごとに、英語論文の該当箇所が" *
    "抜粋として与えられます。その抜粋だけに基づいて、日本語で分かりやすく解説・回答して" *
    "ください。各抜粋には [p.ページ番号] の出典が付いています。回答中で根拠を示す場合は" *
    "その出典を引用してください。抜粋に無いことは推測せず、分からない場合はその旨を" *
    "伝えてください。回答は Markdown で記述してください。"

mutable struct Job
    status::String          # running | done | error
    phase::String           # extracting | embedding | done
    indexed::Bool
    cached::Bool
    reused::Int
    done::Int
    total::Int
    embed_done::Int
    embed_total::Int
    title::String
    dockey::String
    chunks::Vector{String}
    pages::Vector{Int}
    vectors::Vector{Vector{Float64}}
    error::String
    messages::Vector{Dict{String,String}}
end
Job() = Job("running", "extracting", false, false, 0, 0, 0, 0, 0, "", "",
            String[], Int[], Vector{Vector{Float64}}(), "", Dict{String,String}[])

"検索で選ばれたチャンク(重複除去)を `[p.N] 本文` 形式の文脈にする。"
function build_context(chunks, pages, indices)
    lines = ["--- 関連する論文の抜粋 ---"]
    seen = Set{Int}()
    for i in indices
        i in seen && continue
        push!(seen, i)
        push!(lines, "[p.$(pages[i])] $(chunks[i])")
    end
    return join(lines, "\n\n")
end

function apply_cached!(job::Job, data)
    job.title = data["title"]
    job.chunks = String.(data["chunks"])
    job.pages = Int.(data["pages"])
    job.vectors = [Float64.(v) for v in data["vectors"]]
    job.total = get(data, "total", length(job.chunks))
    job.done = job.total
    job.embed_total = length(job.chunks)
    job.embed_done = job.embed_total
    job.cached = true
    job.indexed = true
    job.phase = "done"
    job.status = "done"
    return job
end

# 索引キャッシュから埋め込みキャッシュへ未登録分を移す(ページ範囲違いでも再利用できるように)。
function seed_embeddings(dockey, data)
    try
        mapping = load_embeddings(dockey)
        changed = false
        for (chunk, vec) in zip(data["chunks"], data["vectors"])
            h = text_hash(chunk)
            haskey(mapping, h) || (mapping[h] = vec; changed = true)
        end
        changed && save_embeddings(dockey, mapping)
    catch
    end
end

"`job` を構築する(別タスクで実行する。失敗は `job.status = \"error\"` に記録)。"
function run_index!(job::Job, s::Services, url::AbstractString, pages::Union{Nothing,AbstractString})
    try
        nurl = normalize_url(url)
        key = make_key(nurl, pages)
        dockey = doc_key(nurl)
        job.dockey = dockey
        cached = load_index(key)
        if cached !== nothing
            apply_cached!(job, cached)
            seed_embeddings(dockey, cached)
            return job
        end

        job.phase = "extracting"
        local_pdf, name = download_pdf(url)
        job.title = something(pdf_title(local_pdf), name)
        range = pages === nothing || isempty(strip(pages)) ? nothing : parse_pages(pages)
        raw_pages = extract_blocks(local_pdf, range)
        job.total = sum(length, raw_pages; init = 0)
        job.total == 0 && error("no extractable text found (scanned PDFs need OCR first)")

        start_page = range === nothing ? 1 : range[1]
        chunks = String[]; chunk_pages = Int[]
        for (pi, blocks) in enumerate(raw_pages)
            for block in blocks
                for chunk in split_text(block)
                    push!(chunks, chunk); push!(chunk_pages, start_page + pi - 1)
                end
                job.done += 1
            end
        end
        isempty(chunks) && error("no text to index")
        job.chunks = chunks; job.pages = chunk_pages

        job.embed_total = length(chunks)
        embeddings = load_embeddings(dockey)
        hashes = text_hash.(chunks)
        vectors = Union{Nothing,Vector{Float64}}[haskey(embeddings, h) ? Float64.(embeddings[h]) : nothing for h in hashes]
        job.reused = count(!isnothing, vectors)
        job.embed_done = job.reused

        pending = findall(isnothing, vectors)
        job.phase = "embedding"
        if !isempty(pending)
            new = embed_many(s, chunks[pending], "RETRIEVAL_DOCUMENT"; progress = () -> job.embed_done += 1)
            for (i, v) in zip(pending, new)
                vectors[i] = v
                embeddings[hashes[i]] = v
            end
        end

        job.vectors = Vector{Float64}[v for v in vectors]
        job.indexed = true; job.phase = "done"; job.status = "done"
        try
            save_embeddings(dockey, embeddings)
            save_index(key, Dict("title" => job.title, "chunks" => job.chunks, "pages" => job.pages,
                                 "vectors" => job.vectors, "total" => job.total))
        catch
        end
    catch err
        job.status = "error"
        job.error = err isa Sarashina.SarashinaError ? sprint(showerror, err) : sprint(showerror, err)
    end
    return job
end

"チャンクを ja に翻訳する。既訳はキャッシュから返し API を呼ばない。"
function translate_chunk!(job::Job, s::Services, index::Int)
    text = job.chunks[index]
    digest = text_hash(text)
    translations = isempty(job.dockey) ? Dict{String,Any}() : load_translations(job.dockey)
    haskey(translations, digest) && return String(translations[digest])
    acquire!(s.translate)
    ja = Sarashina.translate(s.client, text; source_lang = "en", target_lang = "ja")
    translations[digest] = ja
    try
        isempty(job.dockey) || save_translations(job.dockey, translations)
    catch
    end
    return ja
end

"直近の会話から次の質問候補を最大 3 件作る。"
function suggest_questions(job::Job, s::Services)
    history = String[]
    for m in job.messages
        m["role"] == "user" && push!(history, "ユーザー: " * m["content"])
        m["role"] == "assistant" && push!(history, "アシスタント: " * m["content"])
    end
    isempty(history) && return String[]
    prompt = "以下は論文についての直近の会話です。\n\n" * join(last(history, 6), "\n") *
             "\n\nこの論文について、ユーザーが次に尋ねると有用な質問を3つ、" *
             "日本語で簡潔に提案してください。質問文だけを1行に1つ、番号や記号を付けずに出力してください。"
    try
        acquire!(s.suggest)
        out = Sarashina.content(Sarashina.chat(s.client, prompt; model = SUGGEST_MODEL))
        lines = [lstrip(c -> c in "-・*0123456789. 　\t", strip(l)) for l in split(out, '\n') if !isempty(strip(l))]
        return String[l for l in lines if !isempty(l)][1:min(3, end)]
    catch
        return String[]
    end
end
