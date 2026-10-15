# Harbor.jl

Harbor runs Docker containers from Julia, mainly for tests that need a real
service such as a database or message broker. It drives the `docker` CLI, so
Docker must be installed and on the `PATH`.

```julia
using Harbor

Harbor.with_container("redis:7"; ports=Dict(6379 => 0),
                      wait_strategy=(pattern="Ready to accept connections",)) do container
    port = Harbor.host_port(container, 6379)
    # connect to 127.0.0.1:port ...
end
```

`with_container` removes the container when the block exits, even on error.
Host port `0` asks Docker for a free port, and `Harbor.host_port` returns it.
See the [README](https://github.com/JuliaServices/Harbor.jl) for the other wait
strategies, environment variables, and cleaning up containers left behind by
crashed processes.

## API

```@autodocs
Modules = [Harbor]
```
