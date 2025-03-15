using Documenter, Harbor

makedocs(modules = [Harbor], sitename = "Harbor.jl")

deploydocs(repo = "github.com/JuliaServices/Harbor.jl.git", push_preview = true)
