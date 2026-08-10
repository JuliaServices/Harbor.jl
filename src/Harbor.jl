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
    name, tag, digest = _check_ref(image, tag)
    @debug "Pulling image" name tag digest
    return docker_pull(name; tag, digest)
end

# Shared reference validation for pull/_resolve_image: returns (name, tag, digest)
# with the effective tag resolved. Digest-pinned pulls create no local tag, so
# their Image records an empty tag.
function _check_ref(image::AbstractString, tag::Union{Nothing, String})
    isempty(image) && throw(ArgumentError("Image name cannot be empty"))
    name, ref_tag, digest = _split_ref(image)
    if ref_tag !== nothing && tag !== nothing && ref_tag != tag
        throw(ArgumentError("conflicting tags: image reference \"$image\" specifies tag \"$ref_tag\" but tag=\"$tag\" was also given"))
    end
    tag = digest === nothing ? something(ref_tag, tag, "latest") : ""
    return String(name), tag, digest
end

# Resolve an image reference for run!/with_container: use the local image when
# present, pulling only when it isn't. Keeps string-form calls usable offline
# and avoids a registry round-trip (and Docker Hub rate-limit exposure) on
# every call.
function _resolve_image(image::AbstractString; tag::Union{Nothing, String}=nothing)::Image
    name, etag, digest = _check_ref(image, tag)
    ref = digest === nothing ? string(name, ":", etag) : string(name, "@", digest)
    present = try
        docker_read(["image", "inspect", "--format", "{{.Id}}", ref])
        true
    catch e
        e isa DockerError || rethrow()
        false
    end
    present && return Image(name, etag, digest)
    return pull(String(image); tag)
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
    @debug "Removing image" image force
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
    if length(s) == 1 && haskey(s, :port) && s.port isa Integer && !(s.port isa Bool)
        return WaitForPort((Int(s.port),))
    elseif length(s) == 1 && haskey(s, :pattern) && s.pattern isa Union{AbstractString, Regex}
        return WaitForLog((s.pattern isa Regex ? s.pattern : String(s.pattern),))
    elseif length(s) == 2 && haskey(s, :url) && haskey(s, :expected_status) &&
           s.url isa AbstractString && s.expected_status isa Integer
        return WaitForHTTP((String(s.url), Int(s.expected_status)))
    elseif length(s) == 1 && haskey(s, :healthy) && s.healthy isa Bool
        return WaitForHealthy((s.healthy,))
    elseif length(s) == 1 && haskey(s, :check) && s.check isa Function
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
    if isempty(container.image.tag)
        println(io, "  Image: ", container.image.name)
    else
        println(io, "  Image: ", container.image.name, ":", container.image.tag)
    end
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
    sock = try
        connect("127.0.0.1", hp)
    catch
        return false  # port is not yet open
    end
    try
        # Docker's userland proxy (docker-proxy/vpnkit) accepts connections
        # itself and only then dials the container, closing on failure — so a
        # successful connect alone proves nothing about the service. Consider
        # the port ready only if the connection is still open shortly after
        # (or the service already sent data).
        closed = @async try
            eof(sock)
        catch
            true  # reset/aborted counts as closed
        end
        if timedwait(() -> istaskdone(closed), 0.25) === :ok && fetch(closed) === true
            return false  # proxy accepted, then closed: backend not listening
        end
        return true
    finally
        close(sock)
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
    ContainerExitedError(strategy, logs)

Thrown when a container exits before satisfying its wait strategy — waiting
longer cannot succeed, so the wait aborts immediately instead of running out
the full `wait_timeout`. Carries the container's logs for diagnosis.
"""
struct ContainerExitedError <: Exception
    strategy::WaitStrategy
    logs::String
end

function Base.showerror(io::IO, e::ContainerExitedError)
    print(io, "ContainerExitedError: container exited before satisfying wait strategy ",
          e.strategy)
    if !isempty(strip(e.logs))
        print(io, "\ncontainer logs:\n", rstrip(e.logs))
    end
end

# best-effort log fetch for wait failure errors
function _logs_or_empty(container::Container)
    try
        docker_logs(container.id; follow=false, tail="all")
    catch
        ""
    end
end

"""
    wait_for(container::Container)

Waits until the container's wait strategy condition is met or `wait_timeout`
expires. Throws a [`WaitTimeoutError`](@ref) (including the container's logs)
if the condition isn't satisfied in time, or a [`ContainerExitedError`](@ref)
as soon as the container exits without having satisfied the strategy.
"""
function wait_for(container::Container)
    strategy = container.options.wait_strategy
    strategy === nothing && return nothing
    start_time = time()
    while true
        check_wait_strategy(strategy, container) && return nothing
        if !is_running(container)
            # the strategy can no longer become true (logs are final; ports/
            # http/health are gone) — but re-check once to close the race
            # where the condition was met just before the container exited
            check_wait_strategy(strategy, container) && return nothing
            throw(ContainerExitedError(strategy, _logs_or_empty(container)))
        end
        if time() - start_time > container.options.wait_timeout
            throw(WaitTimeoutError(strategy, container.options.wait_timeout, _logs_or_empty(container)))
        end
        sleep(container.options.wait_interval)
    end
end

"""
run!(image::Union{Image, AbstractString}; name=nothing, ports=Dict{Int,Int}(),
     volumes=Dict{String,String}(), environment=Dict{String,String}(),
     command=nothing, detach::Bool=true, wait_strategy=nothing,
     wait_timeout=60.0, wait_interval=1.0) -> Container

Starts a container from the provided `Image` — or an image reference string,
which is resolved against local images first and pulled only when absent — and
returns a `Container` handle.

- `ports` maps container ports to host ports; a host port of `0` publishes the
  container port on an OS-assigned ephemeral port (see [`host_port`](@ref)).
  When `ports` is non-empty, no `wait_strategy` is given, and the run is
  detached, `run!` waits for the lowest mapped container port to be ready.
- `wait_strategy` may be `(port=...,)`, `(pattern=string_or_regex,)`,
  `(url=..., expected_status=...)`, `(healthy=true,)`, or a function
  `container -> Bool`. If the strategy is not satisfied within `wait_timeout`
  seconds (or the container exits before satisfying it), the container is
  removed and a [`WaitTimeoutError`](@ref) (or [`ContainerExitedError`](@ref))
  is thrown.
- With `detach=false` the call blocks until the container exits and returns the
  handle even if the container's command exited with a non-zero status; use
  [`logs`](@ref) and [`inspect`](@ref) (`State.ExitCode`) to diagnose.
- `environment` values are forwarded through the docker CLI's process
  environment (not its command line); note that names the docker CLI itself
  reads (`DOCKER_HOST`, `DOCKER_CONFIG`, ...) therefore also affect that one
  CLI invocation.

The started container is force-removed by a garbage-collection finalizer as a
safety net; prefer [`with_container`](@ref) (or explicit [`remove!`](@ref)) for
deterministic cleanup.
"""
function run!(image::Image; ports=Dict{Int,Int}(), wait_strategy=nothing, kw...)::Container
    ports = Dict{Int, Int}(ports)
    wait_strategy = normalize_wait_strategy(wait_strategy)
    # Auto-wait on the lowest mapped container port — but only for detached
    # runs: a foreground run has already exited, so its ports are gone.
    if wait_strategy === nothing && !isempty(ports) && get(kw, :detach, true)
        wait_strategy = WaitForPort((Int(minimum(keys(ports))),))
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
        Dict{Int, Int}(k => v for (k, v) in opts.ports if v != 0)
    end
    # A foreground (detach=false) run only returns once the container exits.
    cont = Container(cid, image, opts.detach ? :running : :exited, now(), opts, resolved_ports; managed=true)
    if opts.wait_strategy !== nothing
        @debug "Waiting for container to be ready using strategy $(opts.wait_strategy)"
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

run!(image::AbstractString; tag::Union{Nothing, String}=nothing, kw...) =
    run!(_resolve_image(image; tag); kw...)

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

Returns the container's full `docker inspect` output as a parsed JSON object.
"""
function inspect(container::Container) :: Dict
    @debug "Inspecting container" container_id=container.id
    return docker_inspect_container(container.id)
end

"""
logs(container::Container; follow::Bool=false, tail="all") -> String

Retrieves the logs (stdout and stderr merged) for the specified container.
With `follow=true` the call blocks until the container stops, then returns the
complete log output. `tail` limits the result to the last N lines.
"""
function logs(container::Container; follow::Bool=false, tail::Union{String,Int}="all") :: String
    @debug "Fetching logs for container" container_id=container.id
    return docker_logs(container.id; follow=follow, tail=tail)
end

"""
exec(container::Container, exec_cmd::AbstractVector{<:AbstractString}; kw...) -> String

Runs a command inside the specified container and returns its stdout. Throws a
[`DockerError`](@ref) carrying the exit code and captured stderr if the command
fails. Supported keywords mirror `docker exec` flags: `env`, `workdir`, `user`,
`detach`, `interactive`, `tty`, `privileged`, `env_file`, `detach_keys`.
`env` values are forwarded through the docker CLI's process environment (not
its command line), so names the docker CLI itself reads (`DOCKER_HOST`, ...)
also affect that one CLI invocation.
"""
function exec(container::Container, exec_cmd::AbstractVector{<:AbstractString}; kw...)::String
    @debug "Executing command in container" container_id=container.id
    return docker_exec(container.id, exec_cmd; kw...)
end

"""
stop!(container::Container; timeout::Int=10) -> Container

Gracefully stops a running container. Returns the `Container` with a new status.
"""
function stop!(container::Container; timeout::Int=10)::Container
    # Stop the container via underlying system calls.
    @debug "Stopping container" container_id=container.id timeout=timeout
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
    @debug "Starting container" container_id=container.id
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
    @debug "Restarting container" container_id=container.id timeout=timeout
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
    @debug "Killing container" container_id=container.id signal=signal
    docker_kill(container.id; signal=signal)
    # a non-fatal signal (e.g. SIGUSR1) leaves the container running
    container.status = is_running(container) ? :running : :exited
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
    @debug "Removing container" container_id=container.id force=force
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

# Docker reports RFC3339Nano timestamps with trailing fractional zeros trimmed
# (e.g. "2026-08-09T12:34:56.78Z"); reduce to millisecond precision.
function _parse_docker_timestamp(s::AbstractString)
    m = match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?", s)
    m === nothing && return nothing
    frac = m.captures[2]
    ms = frac === nothing ? "" : "." * first(rpad(frac, 3, '0'), 3)
    return tryparse(DateTime, m.captures[1] * ms)
end

"""
ps(; all::Bool=true) -> Vector{Container}

Lists containers. If `all` is true, lists all containers; otherwise, only running ones.
"""
function ps(; all::Bool=true)::Vector{Container}
    # Query the underlying system for container info.
    @debug "Listing containers" all=all
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
        img_raw = get(config, "Image", "unknown")
        if startswith(img_raw, "sha256:")
            # a raw image id, not a name[:tag][@digest] reference
            image = Image(String(img_raw), "", nothing)
        else
            img_name, img_tag, img_digest = _split_ref(img_raw)
            image = Image(img_name, something(img_tag, "latest"), img_digest)
        end
        status = Symbol(get(get(info, "State", Dict{String, Any}()), "Status", "unknown"))
        created_raw = get(info, "Created", nothing)
        created_at = created_raw isa AbstractString ? _parse_docker_timestamp(created_raw) : nothing
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
    removed = 0
    for id in ids
        try
            docker_rm(id; force=true)
            removed += 1
        catch e
            @debug "Failed to prune container" container_id=id exception=(e, catch_backtrace())
        end
    end
    return removed
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
    with_container(f, _resolve_image(image; tag); kw...)

end
