# Harbor

Julia package for managing docker images and containers,
with an aim to make testing with external resources simple and easy.

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaServices.github.io/Harbor.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaServices.github.io/Harbor.jl/dev)

GitHub Actions : [![Build Status](https://github.com/JuliaServices/Harbor.jl/workflows/CI/badge.svg)](https://github.com/JuliaServices/Harbor.jl/actions?query=workflow%3ACI+branch%3Amain)

## Installation

```julia
using Pkg
Pkg.add("Harbor")
```

## Usage

```julia
using Harbor

# pull an image
Harbor.pull("alpine")

# list images
Harbor.images()

# run a container
container = Harbor.run!("alpine"; command=["echo", "hello world"])

# list containers
Harbor.ps()

# stop a container
Harbor.stop!(container)

# remove a container
Harbor.remove!(container)

# lifecycle-managed container block
Harbor.with_container("alpine") do container
    # container is automatically stopped and removed at the end of this block
end

```
