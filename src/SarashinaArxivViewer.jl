"""
    SarashinaArxivViewer

arXiv 論文を RAG 化し、その内容を日本語で解説するチャットボット(Web アプリ)。
[Sarashina.jl](https://github.com/atelierarith/Sarashina.jl) で Sarashina API を使う。

    julia --project=. -e 'using SarashinaArxivViewer; serve()'
"""
module SarashinaArxivViewer

using Dates
using Downloads
using HTTP
using JSON
using PDFIO
using SHA
using Sarashina

export serve

include("cache.jl")
include("pdf.jl")
include("rag.jl")
include("indexing.jl")
include("server.jl")

end # module SarashinaArxivViewer
