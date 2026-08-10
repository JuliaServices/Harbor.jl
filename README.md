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

# pull an image ("name", "name:tag", and "name@sha256:..." all work)
Harbor.pull("alpine")

# list images
Harbor.images()

# run a (long-lived) container
container = Harbor.run!("alpine"; command=["sleep", "600"])

# exec in a container (throws a DockerError with exit code + stderr on failure)
output = Harbor.exec(container, ["sh", "-c", "echo -n hi"])

# fetch its logs
Harbor.logs(container)

# list containers (observed containers are never auto-removed by Harbor)
Harbor.ps()

# stop / start / restart / kill a container
Harbor.stop!(container)
Harbor.start!(container)
Harbor.restart!(container)
Harbor.kill!(container)

# remove a container
Harbor.remove!(container; force=true)

# lifecycle-managed container block: the container is force-removed
# synchronously when the block exits (even on error)
Harbor.with_container("alpine") do container
    # ...
end
```

### Ports

Map container ports to host ports with `ports`; use host port `0` to get an
OS-assigned ephemeral port (recommended for CI, where fixed ports collide):

```julia
Harbor.with_container("nginx"; ports=Dict(80 => 0)) do container
    port = Harbor.host_port(container, 80)  # the assigned host port
    # connect to 127.0.0.1:port ...
end
```

When `ports` is given, no `wait_strategy` is specified, and the run is
detached, `run!` waits until the lowest mapped container port is genuinely
ready before returning (a connection must survive docker's userland proxy,
not merely be accepted by it).

### Wait strategies

Control readiness via `wait_strategy` (with `wait_timeout`/`wait_interval`):

```julia
# wait for a mapped container port to accept connections
Harbor.run!("nginx"; ports=Dict(80 => 0), wait_strategy=(port=80,))

# wait for a log line (String or Regex)
Harbor.run!("postgres:16"; environment=Dict("POSTGRES_PASSWORD" => "pw"),
            wait_strategy=(pattern=r"database system is ready",))

# wait for an HTTP response status
Harbor.run!("nginx"; ports=Dict(80 => 8080),
            wait_strategy=(url="http://127.0.0.1:8080/", expected_status=200))

# wait for the image's HEALTHCHECK to report healthy
Harbor.run!("myimage"; wait_strategy=(healthy=true,))

# custom check
Harbor.run!("myimage"; wait_strategy=c -> Harbor.is_running(c))
```

If the strategy isn't satisfied within `wait_timeout` seconds, the container is
removed and a `WaitTimeoutError` is thrown that includes the container's logs.

### Cleanup

Containers started by Harbor are labeled `org.juliaservices.harbor=true` and
force-removed by a GC finalizer as a safety net. For deterministic cleanup use
`with_container`, and to reap containers leaked by crashed processes:

```julia
Harbor.prune()  # force-removes all Harbor-started containers on the host
```
