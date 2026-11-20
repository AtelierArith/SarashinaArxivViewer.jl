# HTTP サーバー(元実装の FastAPI と同じ API)。

const PAGE = read(joinpath(@__DIR__, "page.html"), String)

struct App
    services::Services
    jobs::Dict{String,Job}
    lock::ReentrantLock
end
App(client::Sarashina.Client) = App(Services(client), Dict{String,Job}(), ReentrantLock())

new_job_id() = bytes2hex(rand(UInt8, 16))

struct HTTPError <: Exception
    status::Int
    detail::String
end

function send(http::HTTP.Stream, status::Integer, body::AbstractString, ctype::AbstractString)
    bytes = Vector{UInt8}(body)
    HTTP.setstatus(http, status)
    HTTP.setheader(http, "Content-Type" => ctype)
    HTTP.setheader(http, "Content-Length" => string(length(bytes)))
    HTTP.startwrite(http)
    write(http, bytes)
    return nothing
end
send_json(http, status, obj) = send(http, status, JSON.json(obj), "application/json; charset=utf-8")

function body_json(http::HTTP.Stream)
    raw = String(read(http))
    isempty(raw) && return Dict{String,Any}()
    try
        obj = JSON.parse(raw; dicttype = Dict{String,Any})
        obj isa AbstractDict || throw(HTTPError(422, "JSON object expected"))
        return obj
    catch e
        e isa HTTPError && rethrow()
        throw(HTTPError(422, "invalid JSON"))
    end
end

function get_job(app::App, id)
    job = lock(() -> get(app.jobs, string(id), nothing), app.lock)
    job === nothing && throw(HTTPError(404, "unknown job"))
    return job
end

function field(body, key, T)
    v = get(body, key, nothing)
    v isa T || throw(HTTPError(422, "field `$key` ($T) is required"))
    return v
end

function api_index(app::App, http)
    body = body_json(http)
    url = String(strip(field(body, "url", AbstractString)))
    is_url(url) || throw(HTTPError(400, "URL must start with http(s)://"))
    pages = get(body, "pages", nothing)
    pages = pages isa AbstractString ? String(pages) : nothing
    pages === nothing || isempty(strip(pages)) || try parse_pages(pages) catch e
        throw(HTTPError(400, sprint(showerror, e)))
    end
    id = new_job_id()
    job = Job()
    lock(() -> app.jobs[id] = job, app.lock)
    @async run_index!(job, app.services, url, pages)
    send_json(http, 200, Dict("job_id" => id))
end

function api_index_status(app::App, http, id)
    j = get_job(app, id)
    send_json(http, 200, Dict("status" => j.status, "phase" => j.phase, "indexed" => j.indexed,
        "cached" => j.cached, "done" => j.done, "total" => j.total, "embed_done" => j.embed_done,
        "embed_total" => j.embed_total, "reused" => j.reused, "title" => j.title, "error" => j.error))
end

function api_paper(app::App, http, id)
    j = get_job(app, id)
    j.status == "done" || throw(HTTPError(409, "indexing is not finished"))
    translations = isempty(j.dockey) ? Dict{String,Any}() : load_translations(j.dockey)
    chunks = [Dict("i" => i - 1, "page" => j.pages[i], "text" => j.chunks[i]) for i in eachindex(j.chunks)]
    translated = Dict{String,Any}()
    for i in eachindex(j.chunks)
        ja = get(translations, text_hash(j.chunks[i]), nothing)
        isempty(something(ja, "")) || (translated[string(i - 1)] = ja)
    end
    send_json(http, 200, Dict("title" => j.title, "chunks" => chunks, "translations" => translated))
end

function api_translate(app::App, http)
    body = body_json(http)
    job = get_job(app, field(body, "job_id", AbstractString))
    index = field(body, "index", Integer)
    1 <= index + 1 <= length(job.chunks) || throw(HTTPError(400, "chunk index out of range"))
    ja = try
        translate_chunk!(job, app.services, index + 1)
    catch e
        throw(HTTPError(502, sprint(showerror, e)))
    end
    send_json(http, 200, Dict("index" => index, "text" => ja))
end

function api_suggest(app::App, http)
    body = body_json(http)
    job = get_job(app, field(body, "job_id", AbstractString))
    send_json(http, 200, Dict("suggestions" => suggest_questions(job, app.services)))
end

sse(obj) = "data: " * JSON.json(obj) * "\n\n"

function api_chat(app::App, http)
    body = body_json(http)
    job = get_job(app, field(body, "job_id", AbstractString))
    message = String(field(body, "message", AbstractString))
    job.indexed || throw(HTTPError(409, "RAG index is not built yet"))
    s = app.services

    # 日本語の質問を英訳 → 埋め込み → コサイン top-k → rerank
    indices = try
        acquire!(s.translate)
        query_en = Sarashina.translate(s.client, message; source_lang = "ja", target_lang = "en")
        retrieve(s, query_en, job.chunks, job.vectors)
    catch e
        throw(HTTPError(502, sprint(showerror, e)))
    end
    sources = sort!(unique(job.pages[i] for i in indices))
    context = build_context(job.chunks, job.pages, indices)

    isempty(job.messages) && push!(job.messages, Dict("role" => "system", "content" => INSTRUCTIONS))
    push!(job.messages, Dict("role" => "system", "content" => context))
    push!(job.messages, Dict("role" => "user", "content" => message))

    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "text/event-stream; charset=utf-8")
    HTTP.setheader(http, "Cache-Control" => "no-cache")
    HTTP.startwrite(http)
    try
        acquire!(s.chat)
        answer = Sarashina.chat_stream(s.client, job.messages; model = CHAT_MODEL) do chunk
            for ch in get(chunk, "choices", Any[])
                delta = get(ch, "delta", nothing)
                txt = delta isa AbstractDict ? get(delta, "content", nothing) : nothing
                txt isa AbstractString && !isempty(txt) && write(http, sse(Dict("delta" => txt)))
            end
        end
        push!(job.messages, Dict("role" => "assistant", "content" => answer))
        if !isempty(sources)
            links = join(("<a href=\"#page-$p\">p.$p</a>" for p in sources), ", ")
            write(http, sse(Dict("note" => "参考ページ: " * links)))
        end
        write(http, "data: [DONE]\n\n")
    catch e
        write(http, sse(Dict("error" => sprint(showerror, e))))
    end
    return nothing
end

function route(app::App, http::HTTP.Stream)
    req = http.message
    method = req.method
    path = String(HTTP.URI(req.target).path)
    segs = split(strip(path, '/'), '/'; keepempty = false)
    if method == "GET" && isempty(segs)
        return send(http, 200, PAGE, "text/html; charset=utf-8")
    elseif method == "POST" && segs == ["api", "index"]
        return api_index(app, http)
    elseif method == "GET" && length(segs) == 3 && segs[1:2] == ["api", "index"]
        return api_index_status(app, http, segs[3])
    elseif method == "GET" && length(segs) == 3 && segs[1:2] == ["api", "paper"]
        return api_paper(app, http, segs[3])
    elseif method == "POST" && segs == ["api", "translate"]
        return api_translate(app, http)
    elseif method == "POST" && segs == ["api", "chat"]
        return api_chat(app, http)
    elseif method == "POST" && segs == ["api", "suggest"]
        return api_suggest(app, http)
    end
    throw(HTTPError(404, "not found"))
end

safe_send(http, status, detail) = try send_json(http, status, Dict("detail" => detail)) catch end

function handle(app::App, http::HTTP.Stream)
    try
        route(app, http)
    catch e
        if e isa HTTPError
            safe_send(http, e.status, e.detail)
        else
            @error "request failed" exception = (e, catch_backtrace())
            safe_send(http, 500, sprint(showerror, e))
        end
    end
    return nothing
end

"""
    serve(; host="127.0.0.1", port=8000, client=Sarashina.Client(), wait=true)

Web アプリを起動する。`wait=false` なら起動済みサーバー(`HTTP.Server`)を返す。
API キーは `SARASHINA_API_KEY`(環境変数、またはカレントの `.env`)から読む。
"""
function serve(; host::AbstractString = "127.0.0.1", port::Integer = 8000,
               client::Sarashina.Client = Sarashina.Client(), wait::Bool = true)
    app = App(client)
    server = HTTP.listen!(http -> handle(app, http), host, port)
    @info "Sarashina arXiv RAG: http://$host:$(HTTP.port(server))"
    wait && Base.wait(server)
    return server
end
