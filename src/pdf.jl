# PDF の取得とテキストブロック抽出(PDFIO.jl を使用)。

const MAX_CHARS = 4800   # /v1/translate は 5,000 文字まで

is_url(s::AbstractString) = startswith(s, "http://") || startswith(s, "https://")

"arXiv の `abs` URL を `pdf` URL に変換する。"
function normalize_url(url::AbstractString)
    uri = HTTP.URI(url)
    host = lowercase(uri.host)
    if (host == "arxiv.org" || endswith(host, ".arxiv.org")) && startswith(uri.path, "/abs/")
        return string(HTTP.URI(uri; path = "/pdf/" * uri.path[length("/abs/")+1:end]))
    end
    return String(url)
end

"`\"1-3\"` や `\"2\"` を `(1, 3)` / `(2, 2)` に変換する。"
function parse_pages(value::AbstractString)
    m = match(r"^\s*(\d+)\s*(?:-\s*(\d+))?\s*$", value)
    m === nothing && throw(ArgumentError("invalid page range: $(repr(value)) (例: 1-3)"))
    a = parse(Int, m.captures[1])
    b = m.captures[2] === nothing ? a : parse(Int, m.captures[2])
    (a >= 1 && b >= a) || throw(ArgumentError("invalid page range: $(repr(value))"))
    return (a, b)
end

"(ダウンロードしたファイルのパス, ファイル名)を返す。"
function download_pdf(url::AbstractString)
    url = normalize_url(url)
    name = basename(HTTP.URI(url).path)
    isempty(name) && (name = "download.pdf")
    endswith(lowercase(name), ".pdf") || (name *= ".pdf")
    dest = joinpath(mktempdir(), name)
    Downloads.download(url, dest; headers = ["User-Agent" => "Mozilla/5.0"], timeout = 120)
    return dest, name
end

"""
    paragraphs(text) -> Vector{String}

`pdPageExtractText` が返すページ全体のテキストを段落に分割する。空行で区切り、
さらに「文末記号で終わる短い行」の次を新しい段落とみなす(最終行の短い段落末の検出)。
行末ハイフンは除去して連結する。
"""
function paragraphs(text::AbstractString)
    out = String[]
    groups = Vector{Vector{String}}()   # 空行区切りの行グループ
    cur = String[]
    for raw in split(text, '\n')
        l = strip(replace(raw, '\u00a0' => ' '))
        if isempty(l)
            isempty(cur) || (push!(groups, cur); cur = String[])
        else
            push!(cur, l)
        end
    end
    isempty(cur) || push!(groups, cur)
    for lines in groups
        maxlen = maximum(length, lines)
        buf = String[]
        flush!() = (isempty(buf) || push!(out, join_lines(buf)); empty!(buf))
        for (k, l) in enumerate(lines)
            push!(buf, l)
            if k < length(lines) && length(l) < 0.75 * maxlen && occursin(r"[.!?。.:]\)?$", l)
                flush!()
            end
        end
        flush!()
    end
    return filter!(!isempty, out)
end

function join_lines(lines)
    text = lines[1]
    for l in lines[2:end]
        text = endswith(text, "-") && length(text) > 1 && isletter(text[prevind(text, end)]) ?
               chop(text) * l : text * " " * l
    end
    return String(strip(text))
end

"`pages_range` で限定したページごとのテキストブロック(段落)を返す。"
function extract_blocks(path::AbstractString, pages_range::Union{Nothing,Tuple{Int,Int}} = nothing)
    doc = pdDocOpen(path)
    try
        n = pdDocGetPageCount(doc)
        first_page, last_page = pages_range === nothing ? (1, n) : (pages_range[1], min(pages_range[2], n))
        pages = Vector{Vector{String}}()
        for i in first_page:last_page
            io = IOBuffer()
            pdPageExtractText(io, pdDocGetPage(doc, i))
            push!(pages, paragraphs(String(take!(io))))
        end
        return pages
    finally
        pdDocClose(doc)
    end
end

"PDF メタデータの Title(無ければ `nothing`)。"
function pdf_title(path::AbstractString)
    doc = pdDocOpen(path)
    try
        t = get(pdDocGetInfo(doc), "Title", "")
        t isa AbstractString && !isempty(strip(t)) ? String(strip(t)) : nothing
    catch
        nothing
    finally
        pdDocClose(doc)
    end
end

"長いテキストを `limit` 文字以下に分割する(行境界優先)。"
function split_text(text::AbstractString, limit::Int = MAX_CHARS)
    text = strip(text)
    length(text) <= limit && return isempty(text) ? String[] : [String(text)]
    chunks = String[]
    current = ""
    for line in eachline(IOBuffer(text); keep = true)
        while length(line) > limit
            head = first(line, limit)
            line = line[nextind(line, 0, limit + 1):end]
            isempty(current) || (push!(chunks, strip(current)); current = "")
            push!(chunks, strip(head))
        end
        if length(current) + length(line) > limit
            push!(chunks, strip(current))
            current = line
        else
            current *= line
        end
    end
    isempty(strip(current)) || push!(chunks, strip(current))
    return filter!(!isempty, chunks)
end
