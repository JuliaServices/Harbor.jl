module Harbor

using Dates, Logging, Sockets, JSON

struct Image
    name::String         # e.g., "ubuntu", "myapp"
    tag::String          # e.g., "latest", "1.0.0"
    digest::Union{Nothing, String}  # Optional: cryptographic digest
end

Image(name::String, tag::String="latest") = Image(name, tag, nothing)

include("docker.jl")

"""
pull(image::String; tag::String="latest") -> Image

Pulls an image from a registry and returns an `Image` instance.
"""
function pull(image::String; tag::String="latest")::Image
    @info "Pulling image" image tag=tag
    isempty(image) && throw(ArgumentError("Image name cannot be empty"))
    return docker_pull(image; tag=tag)
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
const WaitForLog = @NamedTuple{pattern::String}
const WaitForHTTP = @NamedTuple{url::String, expected_status::Int}
const CustomWait = @NamedTuple{check::Function}
const WaitStrategy = Union{WaitForPort, WaitForLog, WaitForHTTP, CustomWait}

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

mutable struct Container
    id::String                           # Unique container identifier
    image::Image                         # The image the container was launched from
    status::Symbol                       # e.g., :created, :running, :stopped, :exited
    created_at::Union{DateTime, Nothing} # Timestamp of creation
    options::RunOptions                  # Options used when creating the container

    function Container(id, image, symbol, created_at, options)
        x = new(id, image, symbol, created_at, options)
        finalizer(x) do _
            ids = docker_ps(; all=true)
            for cid in ids
                if cid == id
                    docker_stop(cid)
                    docker_rm(cid; force=true)
                    break
                end
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

    # Ports
    println(io, "    Ports:")
    if isempty(container.options.ports)
        println(io, "      (none)")
    else
        for (cport, hport) in container.options.ports
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
    wait_for(container::Container)

Waits until the given strategy condition is met or the timeout expires.
Throws an error if the wait condition isn't satisfied in time.
"""
function wait_for(container::Container)
    start_time = time()
    strategy = container.options.wait_strategy
    strategy === nothing && return
    while true
        elapsed = time() - start_time
        if elapsed > container.options.wait_timeout
            throw(ErrorException("Wait strategy timeout exceeded"))
        end
        if strategy isa WaitForPort
            host_port = container.options.ports[strategy.port]  # Assumes port mapping exists
            try
                sock = connect("127.0.0.1", host_port)
                close(sock)
                @info "Port $(strategy.port) is listening"
                return true
            catch
                # Port is not yet open
            end
        elseif strategy isa WaitForLog
            logs_output = docker_logs(container.id; follow=false, tail="all")
            if occursin(strategy.pattern, logs_output)
                @info "Found log pattern: $(strategy.pattern)"
                return true
            end
        elseif strategy isa WaitForHTTP
            try
                sock = connect(strategy.url)
                write(sock, "GET / HTTP/1.0\r\n\r\n")
                response = String(read(sock, String))
                if occursin(string(strategy.expected_status), response)
                    @info "HTTP endpoint $(strategy.url) responded with $(strategy.expected_status)"
                    return true
                end
            catch
                # HTTP request failed
            end
        elseif strategy isa CustomWait
            if strategy.check(container)
                @info "Custom wait condition satisfied"
                return true
            end
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
    if wait_strategy === nothing && !isempty(ports)
        wait_strategy = (port=first(keys(ports)),)
    end
    opts = RunOptions(; ports, wait_strategy, kw...)
    # Call underlying runtime to create and start the container.
    cid = docker_run(image; name=opts.name, ports=opts.ports, volumes=opts.volumes,
        environment=opts.environment, command=opts.command, detach=opts.detach)
    cont = Container(cid, image, :running, now(), opts)
    if opts.wait_strategy !== nothing
        @info "Waiting for container to be ready using strategy $(opts.wait_strategy)"
        wait_for(cont)
    end
    return cont
end

run!(image; tag::String="latest", kw...) = run!(pull(image; tag=tag); kw...)

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
remove!(container::Container) -> Bool

Removes a container from the system. Returns `true` if successful.
"""
function remove!(container::Container; force::Bool=false)::Bool
    # Remove container logic.
    @info "Removing container" container_id=container.id force=force
    return docker_rm(container.id; force=force)
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
        info = docker_inspect_container(id)
        # get image from inspect result
        img = get(get(info, "Config", Dict()), "Image", "unknown")
        tag = get(get(info, "Config", Dict()), "Tag", "unknown")
        image = Image(img, tag)
        status = Symbol(get(get(info, "State", Dict()), "Status", "unknown"))
        created_at = get(info, "Created", nothing)
        if created_at !== nothing
            created_at = DateTime(created_at[1:min(sizeof(created_at), 23)])
        end
        # run options
        name = get(info, "Name", nothing)
        ports = Dict{Int, Int}()
        for (k, v) in get(get(info, "HostConfig", Dict()), "PortBindings", Dict())
            # key is like: "80/tcp"
            ports[parse(Int, split(k, "/")[1])] = parse(Int, v[1]["HostPort"])
        end
        volumes = Dict{String, String}()
        for (k, v) in something(get(get(info, "HostConfig", Dict()), "Binds", Dict()), Dict())
            # key is like: "/host/path:/container/path"
            volumes[split(k, ":")[2]] = split(v, ":")[1]
        end
        env_vars = get(get(info, "Config", Dict()), "Env", String[])
        environment = Dict{String, String}()
        for env in env_vars
            key, val = split(env, "="; limit=2)
            environment[key] = val
        end
        command = String[x for x in get(get(info, "Config", Dict()), "Cmd", String[])]
        detach = get(get(info, "HostConfig", Dict()), "NetworkMode", "default") == "bridge"
        cont = Container(id, image, status, created_at, RunOptions(; name, ports, volumes, environment, command, detach))
        push!(containers, cont)
    end
    return containers
end

"""
with_container(image::Image; kw...) do container
    # operations on container
end

Runs a container with the specified image and keyword options. The container is automatically
stopped and removed after the block completes (even if an error occurs).
"""
function with_container(f::Function, image::Image; container_logs_on_error::Bool=false, kw...)
    container = run!(image; kw...)
    try
        return f(container)
    catch
        if container_logs_on_error
            logs_output = docker_logs(container.id; follow=false, tail="all")
            @error logs_output
        end
        rethrow()
    finally
        finalize(container)
    end
end

with_container(f::Function, image::String; tag="latest", kw...) = with_container(f, pull(image; tag=tag); kw...)

end
