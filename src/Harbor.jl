module Harbor

using Dates, Logging, Sockets, JSON

struct Image
    name::String         # e.g., "ubuntu", "myapp"
    tag::String          # e.g., "latest", "1.0.0"
    digest::Union{Nothing, String}  # Optional: cryptographic digest
end

Image(name::String, tag::String="latest") = Image(name, tag, nothing)

# Split an image reference "name[:tag][@digest]" into its parts. A ':' only
# counts as a tag separator when it appears after the last '/', so registry
# hosts with ports ("localhost:5000/img") parse correctly.
function _split_ref(ref::AbstractString)
    name = ref
    digest = nothing
    i = findlast('@', name)
    if i !== nothing
        digest = String(name[i+1:end])
        name = name[1:i-1]
    end
    slash = findlast('/', name)
    colon = findlast(':', name)
    tag = nothing
    if colon !== nothing && (slash === nothing || colon > slash)
        tag = String(name[colon+1:end])
        name = name[1:colon-1]
    end
    return String(name), tag, digest
end

include("docker.jl")

"""
pull(image::String; tag::Union{Nothing, String}=nothing) -> Image

Pulls an image from a registry and returns an `Image` instance. `image` may be
a bare name (`"alpine"`), include a tag (`"alpine:3.19"`), or be pinned to a
digest (`"alpine@sha256:..."`). When no tag is given in either the reference or
the `tag` keyword, `"latest"` is used. The returned `Image` records the
image's registry digest when it can be determined.
"""
function pull(image::String; tag::Union{Nothing, String}=nothing)::Image
    isempty(image) && throw(ArgumentError("Image name cannot be empty"))
    name, ref_tag, digest = _split_ref(image)
    if ref_tag !== nothing && tag !== nothing && ref_tag != tag
        throw(ArgumentError("conflicting tags: image reference \"$image\" specifies tag \"$ref_tag\" but tag=\"$tag\" was also given"))
    end
    tag = something(ref_tag, tag, "latest")
    @info "Pulling image" name tag digest
    return docker_pull(name; tag, digest)
end

"""
images() -> Vector{Image}

Retrieves a list of available images.
"""
images()::Vector{Image} = docker_images()

"""
remove(image::Image; force::Bool=false) -> Bool

Removes the specified image.
"""
function remove(image::Image; force::Bool=false)::Bool
    @info "Removing image" image force
    return docker_rm_image(image; force=force)
end

const WaitForPort = @NamedTuple{port::Int}
const WaitForLog = @NamedTuple{pattern::Union{String, Regex}}
const WaitForHTTP = @NamedTuple{url::String, expected_status::Int}
const WaitForHealthy = @NamedTuple{healthy::Bool}
const CustomWait = @NamedTuple{check::Function}
const WaitStrategy = Union{WaitForPort, WaitForLog, WaitForHTTP, WaitForHealthy, CustomWait}

# Validate and canonicalize a user-provided wait strategy. Accepts the
# documented NamedTuple shapes (with any field order / integer types) or a
# bare function treated as a custom check, throwing a descriptive error for
# anything else (previously an unrecognized strategy silently looped until
# the wait timeout expired).
normalize_wait_strategy(::Nothing) = nothing
normalize_wait_strategy(f::Function) = CustomWait((f,))
function normalize_wait_strategy(s::NamedTuple)
    if length(s) == 1 && haskey(s, :port)
        return WaitForPort((Int(s.port),))
    elseif length(s) == 1 && haskey(s, :pattern)
        return WaitForLog((s.pattern,))
    elseif length(s) == 2 && haskey(s, :url) && haskey(s, :expected_status)
        return WaitForHTTP((String(s.url), Int(s.expected_status)))
    elseif length(s) == 1 && haskey(s, :healthy)
        return WaitForHealthy((Bool(s.healthy),))
    elseif length(s) == 1 && haskey(s, :check)
        return CustomWait((s.check,))
    end
    throw(ArgumentError("unrecognized wait_strategy $s; expected (port=...,), (pattern=...,), " *
                        "(url=..., expected_status=...), (healthy=true,), (check=...,), or a function"))
end
normalize_wait_strategy(other) =
    throw(ArgumentError("wait_strategy must be a NamedTuple or a function, got $(typeof(other))"))

@kwdef struct RunOptions
    name::Union{Nothing, String} = nothing
    ports::Dict{Int, Int} = Dict{Int, Int}()
    volumes::Dict{String, String} = Dict{String, String}()
    environment::Dict{String, String} = Dict{String, String}()
    command::Union{Nothing, Vector{String}} = nothing
    detach::Bool = true
    wait_timeout::Float64 = 60.0
    wait_interval::Float64 = 1.0
    wait_strategy::Union{Nothing, WaitStrategy} = nothing
end

# Label applied to every container started by Harbor, so leaked containers
# can be identified (and removed via `prune`).
const HARBOR_LABEL = "org.juliaservices.harbor"

mutable struct Container
    id::String                           # Unique container identifier
    image::Image                         # The image the container was launched from
    status::Symbol                       # e.g., :created, :running, :stopped, :exited, :removed
    created_at::Union{DateTime, Nothing} # Timestamp of creation
    options::RunOptions                  # Options used when creating the container
    ports::Dict{Int, Int}                # Resolved container port => host port mappings
    cleaned_up::Bool                     # true once the container has been removed

    function Container(id, image, status, created_at, options, ports=Dict{Int, Int}(); managed::Bool=false)
        x = new(id, image, status, created_at, options, ports, false)
        # Only containers started by Harbor (`managed=true`) get a cleanup
        # finalizer; containers merely observed via `ps` must never be
        # stopped or removed just because their in-memory handle was GC'd.
        managed && finalizer(x) do c
            c.cleaned_up && return
            # Must use @async because finalizers cannot perform task switches
            # (I/O operations like docker commands require task switches)
            @async try
                docker_rm(c.id; force=true)
            catch e
                @debug "Container cleanup failed" container_id=c.id exception=(e, catch_backtrace())
            end
        end
        return x
    end
end

function Base.show(io::IO, container::Container)
    println(io, "Container:")
    println(io, "  ID: ", container.id)
    println(io, "  Image: ", container.image.name, ":", container.image.tag)
    if container.image.digest !== nothing
        println(io, "         Digest: ", container.image.digest)
    end
    println(io, "  Status: ", container.status)
    println(io, "  Created At: ", isnothing(container.created_at) ? "N/A" : string(container.created_at))
    println(io, "  Run Options:")
    
    # Name
    if container.options.name !== nothing
        println(io, "    Name: ", container.options.name)
    else
        println(io, "    Name: (none)")
    end

    # Ports (resolved mappings, including ephemeral host port assignments)
    println(io, "    Ports:")
    if isempty(container.ports)
        println(io, "      (none)")
    else
        for (cport, hport) in container.ports
            println(io, "      Container Port ", cport, " -> Host Port ", hport)
        end
    end

    # Volumes
    println(io, "    Volumes:")
    if isempty(container.options.volumes)
        println(io, "      (none)")
    else
        for (cpath, hpath) in container.options.volumes
            println(io, "      Container Path: ", cpath, " -> Host Path: ", hpath)
        end
    end

    # Environment variables
    println(io, "    Environment:")
    if isempty(container.options.environment)
        println(io, "      (none)")
    else
        for (key, val) in container.options.environment
            println(io, "      ", key, " = ", val)
        end
    end

    # Command and detach flag
    cmd_str = container.options.command === nothing ? "(none)" : join(container.options.command, " ")
    println(io, "    Command: ", cmd_str)
    println(io, "    Detach: ", container.options.detach)
end

"""
    WaitTimeoutError(strategy, timeout, logs)

Thrown when a container fails to satisfy its wait strategy within
`wait_timeout` seconds. Carries the container's logs at the time the wait
gave up to make failures diagnosable.
"""
struct WaitTimeoutError <: Exception
    strategy::WaitStrategy
    timeout::Float64
    logs::String
end

function Base.showerror(io::IO, e::WaitTimeoutError)
    print(io, "WaitTimeoutError: container did not satisfy wait strategy ",
          e.strategy, " within ", e.timeout, " seconds")
    if !isempty(strip(e.logs))
        print(io, "\ncontainer logs:\n", rstrip(e.logs))
    end
end

# Parse "http://host[:port][/path]" into (host, port, path).
function _parse_http_url(url::AbstractString)
    m = match(r"^http://([^/:]+)(?::(\d+))?(/.*)?$", url)
    m === nothing && throw(ArgumentError("WaitForHTTP only supports plain http://host[:port][/path] URLs, got: $url"))
    host = String(m.captures[1])
    port = m.captures[2] === nothing ? 80 : parse(Int, m.captures[2])
    path = m.captures[3] === nothing ? "/" : String(m.captures[3])
    return host, port, path
end

# One readiness probe per strategy; returns true when the condition holds.
function check_wait_strategy(s::WaitForPort, container::Container)
    hp = get(container.ports, s.port, nothing)
    hp === nothing && throw(ArgumentError("wait strategy (port=$(s.port),) has no matching entry in the container's port mappings"))
    try
        close(connect("127.0.0.1", hp))
        return true
    catch
        return false  # port is not yet open
    end
end

check_wait_strategy(s::WaitForLog, container::Container) =
    occursin(s.pattern, docker_logs(container.id; follow=false, tail="all"))

function check_wait_strategy(s::WaitForHTTP, container::Container)
    host, port, path = _parse_http_url(s.url)
    try
        sock = connect(host, port)
        try
            write(sock, "GET $path HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n")
            response = read(sock, String)
            status_line = first(split(response, "\r\n"; limit=2))
            parts = split(status_line, ' '; limit=3)
            return length(parts) >= 2 && tryparse(Int, parts[2]) == s.expected_status
        finally
            close(sock)
        end
    catch
        return false  # connection refused / reset while the server starts up
    end
end

function check_wait_strategy(s::WaitForHealthy, container::Container)
    s.healthy || return true
    info = docker_inspect_container(container.id)
    health = get(get(info, "State", Dict{String, Any}()), "Health", nothing)
    health === nothing && throw(ArgumentError("wait strategy (healthy=true,) requires the image to define a HEALTHCHECK, but the container has none"))
    return get(health, "Status", "") == "healthy"
end

check_wait_strategy(s::CustomWait, container::Container) = s.check(container) === true

"""
    wait_for(container::Container)

Waits until the container's wait strategy condition is met or `wait_timeout`
expires. Throws a [`WaitTimeoutError`](@ref) (including the container's logs)
if the condition isn't satisfied in time.
"""
function wait_for(container::Container)
    strategy = container.options.wait_strategy
    strategy === nothing && return nothing
    start_time = time()
    while true
        check_wait_strategy(strategy, container) && return nothing
        if time() - start_time > container.options.wait_timeout
            logs_output = try
                docker_logs(container.id; follow=false, tail="all")
            catch
                ""
            end
            throw(WaitTimeoutError(strategy, container.options.wait_timeout, logs_output))
        end
        sleep(container.options.wait_interval)
    end
end

"""
run!(image::Image; name=nothing, ports=Dict{Int,Int}(), 
              volumes=Dict{String,String}(), environment=Dict{String,String}(), 
              command=nothing, detach::Bool=false) -> Container

Starts a container from the provided `Image` with the specified options.
Returns a `Container` instance reflecting the running state.
"""
function run!(image::Image; ports=Dict{Int,Int}(), wait_strategy=nothing, kw...)::Container
    ports = Dict{Int, Int}(ports)
    wait_strategy = normalize_wait_strategy(wait_strategy)
    if wait_strategy === nothing && !isempty(ports)
        wait_strategy = WaitForPort((Int(first(keys(ports))),))
    end
    opts = RunOptions(; ports, wait_strategy, kw...)
    # Call underlying runtime to create and start the container. The label
    # marks the container as Harbor-managed so `prune` can find leaked ones.
    cid = docker_run(image; name=opts.name, ports=opts.ports, volumes=opts.volumes,
        environment=opts.environment, command=opts.command, detach=opts.detach,
        labels=Dict(HARBOR_LABEL => "true"))
    # Resolve the actual host ports (ephemeral requests may differ from the
    # requested mapping).
    resolved_ports = isempty(opts.ports) ? Dict{Int, Int}() : try
        docker_resolved_ports(cid)
    catch e
        @debug "Failed to resolve container ports" container_id=cid exception=(e, catch_backtrace())
        copy(opts.ports)
    end
    # A foreground (detach=false) run only returns once the container exits.
    cont = Container(cid, image, opts.detach ? :running : :exited, now(), opts, resolved_ports; managed=true)
    if opts.wait_strategy !== nothing
        @info "Waiting for container to be ready using strategy $(opts.wait_strategy)"
        try
            wait_for(cont)
        catch
            # the caller never receives the container handle, so remove the
            # container rather than leaking it
            cleanup!(cont)
            rethrow()
        end
    end
    return cont
end

run!(image::AbstractString; tag::Union{Nothing, String}=nothing, kw...) = run!(pull(String(image); tag); kw...)

"""
    host_port(container::Container, container_port::Integer) -> Int

Returns the host port that `container_port` is published on. This is the
canonical way to reach a container whose ports were requested with an
ephemeral host port (`ports=Dict(container_port => 0)`). Throws an
`ArgumentError` if the container port is not published.
"""
function host_port(container::Container, container_port::Integer)::Int
    hp = get(container.ports, Int(container_port), nothing)
    hp === nothing && throw(ArgumentError("container port $container_port is not published to a host port (published: $(container.ports))"))
    return hp
end

"""
inspect(container::Container) -> Dict

"""
function inspect(container::Container) :: Dict
    @info "Inspecting container" container_id=container.id
    return docker_inspect_container(container.id)
end

"""
logs(container::Container) -> String

Retrieves the logs for the specified container.
"""
function logs(container::Container; follow::Bool=false, tail::Union{String,Int}="all") :: String
    @info "Fetching logs for container" container_id=container.id
    return docker_logs(container.id; follow=follow, tail=tail)
end

"""
exec(container::Container, exec_cmd::AbstractVector{<:AbstractString}; kw...) -> String

Runs a command inside the specified container.
"""
function exec(container::Container, exec_cmd::AbstractVector{<:AbstractString}; kw...)::String
    @info "Executing command in container" container_id=container.id
    return docker_exec(container.id, exec_cmd; kw...)
end

"""
stop!(container::Container; timeout::Int=10) -> Container

Gracefully stops a running container. Returns the `Container` with a new status.
"""
function stop!(container::Container; timeout::Int=10)::Container
    # Stop the container via underlying system calls.
    @info "Stopping container" container_id=container.id timeout=timeout
    docker_stop(container.id; timeout=timeout)
    container.status = :stopped
    return container
end

"""
    start!(container::Container) -> Container

Starts a stopped container. Returns the `Container` with an updated status
and refreshed host port mappings (ephemeral ports may be re-assigned).
"""
function start!(container::Container)::Container
    @info "Starting container" container_id=container.id
    docker_start(container.id)
    container.status = :running
    isempty(container.options.ports) || (container.ports = docker_resolved_ports(container.id))
    return container
end

"""
    restart!(container::Container; timeout::Int=10) -> Container

Restarts a container (stopping it first if running, with `timeout` seconds of
grace). Returns the `Container` with an updated status and refreshed host
port mappings.
"""
function restart!(container::Container; timeout::Int=10)::Container
    @info "Restarting container" container_id=container.id timeout=timeout
    docker_restart(container.id; timeout=timeout)
    container.status = :running
    isempty(container.options.ports) || (container.ports = docker_resolved_ports(container.id))
    return container
end

"""
    kill!(container::Container; signal="SIGKILL") -> Container

Sends `signal` to the container's main process (default `SIGKILL`).
Returns the `Container` with an updated status.
"""
function kill!(container::Container; signal::Union{String, Int}="SIGKILL")::Container
    @info "Killing container" container_id=container.id signal=signal
    docker_kill(container.id; signal=signal)
    container.status = :exited
    return container
end

"""
    is_running(container::Container) -> Bool

Queries docker for the container's live state. Returns `false` if the
container no longer exists.
"""
function is_running(container::Container)::Bool
    info = try
        docker_inspect_container(container.id)
    catch e
        e isa DockerError && return false
        rethrow()
    end
    return get(get(info, "State", Dict{String, Any}()), "Running", false) === true
end

"""
remove!(container::Container; force::Bool=false) -> Bool

Removes a container from the system. Returns `true` if successful.
"""
function remove!(container::Container; force::Bool=false)::Bool
    # Remove container logic.
    @info "Removing container" container_id=container.id force=force
    docker_rm(container.id; force=force)
    container.cleaned_up = true
    container.status = :removed
    return true
end

"""
    cleanup!(container::Container)

Synchronously force-remove the container (stopping it if necessary). Safe to
call multiple times; does nothing if the container was already removed via
`remove!` or a previous `cleanup!`. Errors during removal are logged at debug
level and otherwise ignored.
"""
function cleanup!(container::Container)
    container.cleaned_up && return nothing
    container.cleaned_up = true
    try
        docker_rm(container.id; force=true)
    catch e
        @debug "Container cleanup failed" container_id=container.id exception=(e, catch_backtrace())
    end
    container.status = :removed
    return nothing
end

"""
ps(; all::Bool=true) -> Vector{Container}

Lists containers. If `all` is true, lists all containers; otherwise, only running ones.
"""
function ps(; all::Bool=true)::Vector{Container}
    # Query the underlying system for container info.
    @info "Listing containers" all=all
    ids = docker_ps(; all=all)
    containers = Container[]
    for id in ids
        # a container can vanish between the ps listing and the inspect call
        info = try
            docker_inspect_container(id)
        catch e
            e isa DockerError && continue
            rethrow()
        end
        config = get(info, "Config", Dict{String, Any}())
        hostconfig = get(info, "HostConfig", Dict{String, Any}())
        img_name, img_tag, img_digest = _split_ref(get(config, "Image", "unknown"))
        image = Image(img_name, something(img_tag, "latest"), img_digest)
        status = Symbol(get(get(info, "State", Dict{String, Any}()), "Status", "unknown"))
        created_raw = get(info, "Created", nothing)
        # e.g. "2026-08-09T12:34:56.789123456Z": keep millisecond precision
        created_at = created_raw isa AbstractString ?
            tryparse(DateTime, created_raw[1:min(sizeof(created_raw), 23)]) : nothing
        # inspect reports names with a leading '/'
        name = get(info, "Name", nothing)
        name isa AbstractString && (name = String(lstrip(name, '/')))
        ports = Dict{Int, Int}()
        for (k, v) in something(get(hostconfig, "PortBindings", nothing), Dict{String, Any}())
            # key is like: "80/tcp"; value is null for unbound exposed ports
            (v === nothing || isempty(v)) && continue
            container_port = tryparse(Int, first(split(k, "/")))
            host_port = tryparse(Int, string(get(v[1], "HostPort", "")))
            (container_port === nothing || host_port === nothing) && continue
            ports[container_port] = host_port
        end
        volumes = Dict{String, String}()
        # Binds is an array of "/host/path:/container/path[:opts]" strings
        for bind in something(get(hostconfig, "Binds", nothing), [])
            parts = split(bind, ":")
            length(parts) >= 2 || continue
            volumes[String(parts[2])] = String(parts[1])
        end
        environment = Dict{String, String}()
        for env in something(get(config, "Env", nothing), [])
            kv = split(env, "="; limit=2)
            length(kv) == 2 && (environment[String(kv[1])] = String(kv[2]))
        end
        command = String[string(x) for x in something(get(config, "Cmd", nothing), [])]
        cont = Container(id, image, status, created_at,
            RunOptions(; name, ports, volumes, environment, command),
            _parse_network_ports(info))
        push!(containers, cont)
    end
    return containers
end

"""
    prune() -> Int

Force-removes **all** containers on the host that were started by Harbor
(identified by the `$HARBOR_LABEL` label), including ones leaked by
crashed or killed Julia processes. Returns the number of containers removed.
Containers not started by Harbor are never touched.
"""
function prune()::Int
    ids = docker_ps(; all=true, label=HARBOR_LABEL * "=true")
    for id in ids
        try
            docker_rm(id; force=true)
        catch e
            @debug "Failed to prune container" container_id=id exception=(e, catch_backtrace())
        end
    end
    return length(ids)
end

"""
with_container(image::Image; kw...) do container
    # operations on container
end

Runs a container with the specified image and keyword options. The container is
force-removed synchronously after the block completes (even if an error occurs),
so by the time `with_container` returns, the container is gone and its name and
ports are free for reuse. If a graceful shutdown is required, call `stop!` on
the container at the end of the block.

If `container_logs_on_error=true`, the container's logs are logged with `@error`
before the block's exception is rethrown.
"""
function with_container(f::Function, image::Image; container_logs_on_error::Bool=false, kw...)
    container = run!(image; kw...)
    try
        return f(container)
    catch
        if container_logs_on_error
            logs_output = try
                docker_logs(container.id; follow=false, tail="all")
            catch e
                "failed to fetch container logs: " * sprint(showerror, e)
            end
            @error "with_container block failed; container logs:\n" * logs_output
        end
        rethrow()
    finally
        cleanup!(container)
    end
end

with_container(f::Function, image::AbstractString; tag::Union{Nothing, String}=nothing, kw...) =
    with_container(f, pull(String(image); tag); kw...)

end
