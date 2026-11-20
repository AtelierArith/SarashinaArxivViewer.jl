# ディスクキャッシュ(索引 / 埋め込み / 翻訳)。キーの付け方は元の Python 実装に合わせる。

"キャッシュディレクトリ。`SARASHINA_CACHE_DIR` で変更可。"
function cache_dir()
    dir = get(ENV, "SARASHINA_CACHE_DIR", joinpath(homedir(), ".cache", "sarashina-client"))
    mkpath(dir)
    return dir
end

const ARXIV_PATH = r"^/(?:abs|pdf)/(.+?)(?:\.pdf)?$"

"arXiv の URL なら ID(例 `1706.03762`、`cs/0101001`)を返す。それ以外は `nothing`。"
function arxiv_id(url::AbstractString)
    uri = HTTP.URI(url)
    host = lowercase(uri.host)
    (host == "arxiv.org" || endswith(host, ".arxiv.org")) || return nothing
    m = match(ARXIV_PATH, uri.path)
    return m === nothing ? nothing : String(m.captures[1])
end

sanitize(s::AbstractString) = replace(s, r"[^0-9A-Za-z._-]" => "-")

text_hash(text::AbstractString) = bytes2hex(sha1(text))

"文書単位のキー(ページ範囲を含まない)。"
function doc_key(url::AbstractString)
    id = arxiv_id(url)
    id === nothing || return "arxiv-" * sanitize(id)
    return "url-" * first(text_hash(url), 16)
end

"索引全体のキー(文書 + ページ範囲)。"
function make_key(url::AbstractString, pages::Union{Nothing,AbstractString})
    part = pages === nothing || isempty(strip(pages)) ? "all" : sanitize(strip(pages))
    return "$(doc_key(url))__pages-$part"
end

_path(key) = joinpath(cache_dir(), key * ".json")
_embed_path(doc) = _path(doc * "__embeddings")
_translation_path(doc) = _path(doc * "__translations")

function read_json(path)
    isfile(path) || return nothing
    try
        return JSON.parse(read(path, String); dicttype = Dict{String,Any})
    catch
        return nothing
    end
end

function write_json(path, data)
    tmp = path * ".tmp"
    write(tmp, JSON.json(data))
    mv(tmp, path; force = true)
end

load_embeddings(doc) = something(read_json(_embed_path(doc)), Dict{String,Any}())
save_embeddings(doc, map) = write_json(_embed_path(doc), map)
load_translations(doc) = something(read_json(_translation_path(doc)), Dict{String,Any}())
save_translations(doc, map) = write_json(_translation_path(doc), map)
load_index(key) = read_json(_path(key))
save_index(key, data) = write_json(_path(key), data)
