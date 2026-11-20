# 埋め込み / リランク / 検索。RPM 制限は固定窓ではなくスライディング窓で余裕を持って守る。

const EMBED_MAX_CALLS = 55     # sarashina3-embedding は 60 RPM
const EMBED_MAX_WORKERS = 4
const TRANSLATE_MAX_CALLS = 25 # sarashina3.2-translate は 30 RPM
const CHAT_MAX_CALLS = 25      # sarashina3.2-mini-thinking は 30 RPM
const RERANK_MAX_CALLS = 55    # sarashina3-rerank は 60 RPM
const SUGGEST_MAX_CALLS = 55   # sarashina3-nano は 60 RPM

"`period` 秒あたり `max_calls` 回までに制限するスライディング窓レートリミッタ。"
mutable struct RateLimiter
    max_calls::Int
    period::Float64
    times::Vector{Float64}
    lock::ReentrantLock
end
RateLimiter(max_calls::Integer, period::Real = 60.0) =
    RateLimiter(Int(max_calls), Float64(period), Float64[], ReentrantLock())

function acquire!(rl::RateLimiter)
    while true
        wait_s = lock(rl.lock) do
            now = time()
            filter!(t -> now - t < rl.period, rl.times)
            if length(rl.times) < rl.max_calls
                push!(rl.times, now)
                return 0.0
            end
            return rl.period - (now - rl.times[1])
        end
        wait_s <= 0 && return
        sleep(max(wait_s, 0.01))
    end
end

"API クライアントとモデルごとのレートリミッタ。"
struct Services
    client::Sarashina.Client
    embed::RateLimiter
    translate::RateLimiter
    chat::RateLimiter
    rerank::RateLimiter
    suggest::RateLimiter
end
Services(client::Sarashina.Client) = Services(client,
    RateLimiter(EMBED_MAX_CALLS), RateLimiter(TRANSLATE_MAX_CALLS), RateLimiter(CHAT_MAX_CALLS),
    RateLimiter(RERANK_MAX_CALLS), RateLimiter(SUGGEST_MAX_CALLS))

function embed_text(s::Services, text::AbstractString, task_type::AbstractString)
    acquire!(s.embed)
    return Sarashina.embed(s.client, text; task_type)
end

"`texts` を最大 `workers` 並列で埋め込む。1 件終わるごとに `progress()` を呼ぶ。"
function embed_many(s::Services, texts::AbstractVector{<:AbstractString}, task_type::AbstractString;
                    progress = () -> nothing, workers::Int = EMBED_MAX_WORKERS)
    results = Vector{Vector{Float64}}(undef, length(texts))
    queue = Channel{Int}(length(texts))
    foreach(i -> put!(queue, i), eachindex(texts))
    close(queue)
    @sync for _ in 1:min(workers, max(length(texts), 1))
        @async for i in queue
            results[i] = embed_text(s, texts[i], task_type)
            progress()
        end
    end
    return results
end

function cosine(a::AbstractVector, b::AbstractVector)
    na = sqrt(sum(abs2, a)); nb = sqrt(sum(abs2, b))
    return (na == 0 || nb == 0) ? 0.0 : sum(a .* b) / (na * nb)
end

"""
    retrieve(s, query_en, chunks, vectors; candidate_k=20, final_k=5) -> Vector{Int}

英語クエリを `RETRIEVAL_QUERY` で埋め込み、コサイン類似度 top-`candidate_k` を
`sarashina3-rerank` で再順位付けして上位 `final_k` 件のチャンク番号(1 始まり)を返す。
"""
function retrieve(s::Services, query_en::AbstractString, chunks, vectors;
                  candidate_k::Int = 20, final_k::Int = 5)
    isempty(chunks) && return Int[]
    qv = embed_text(s, query_en, "RETRIEVAL_QUERY")
    order = sortperm([cosine(qv, v) for v in vectors]; rev = true)
    cand = order[1:min(candidate_k, length(order))]
    acquire!(s.rerank)
    ranked = Sarashina.rerank(s.client, query_en, String[chunks[i] for i in cand]; task_type = "GENERAL_QA")
    return [cand[r.document_id] for r in ranked[1:min(final_k, length(ranked))]]
end
