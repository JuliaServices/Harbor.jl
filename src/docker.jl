"""
    DockerError(cmd, exitcode, stderr)

Exception thrown when a `docker` CLI invocation exits with a non-zero status.
Carries the failed command, its exit code, and any captured stderr output.
"""
struct DockerError <: Exception
    cmd::Cmd
    exitcode::Int
    stderr::String
end

function Base.showerror(io::IO, e::DockerError)
    print(io, "DockerError: command ", e.cmd, " failed with exit code ", e.exitcode)
    if !isempty(strip(e.stderr))
        print(io, ":\n", rstrip(e.stderr))
    end
end

# Run a docker CLI command, returning captured stdout as a String.
# stderr is captured and included in the DockerError thrown on failure.
# With `stderr_to_stdout=true`, stderr is merged into the returned output instead.
function docker_read(args::Vector{String}; env=nothing, stderr_to_stdout::Bool=false)::String
    cmd = Cmd(vcat(["docker"], args))
    if env !== nothing
        cmd = addenv(cmd, env)
    end
    out = IOBuffer()
    err = stderr_to_stdout ? out : IOBuffer()
    proc = try
        run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    catch e
        if e isa Base.IOError
            throw(ArgumentError("could not run the `docker` CLI — is Docker installed and on the PATH?"))
        end
        rethrow()
    end
    output = String(take!(out))
    if !success(proc)
        throw(DockerError(cmd, proc.exitcode, stderr_to_stdout ? output : String(take!(err))))
    end
    return output
end

# The CLI reference for an image: pinned to its digest when known, else name:tag.
image_ref(image::Image) = image.digest === nothing ? string(image.name, ":", image.tag) : string(image.name, "@", image.digest)

"""
    docker_pull(image_name::String; tag::String="latest", digest=nothing) -> Image

Runs `docker pull <image_name>:<tag>` (or `<image_name>@<digest>` when a digest
is given). On success, returns an `Image` struct with the image's registry
digest populated when it can be determined.
"""
function docker_pull(image_name::String; tag::String="latest",
                     digest::Union{Nothing, String}=nothing)::Image
    ref = digest === nothing ? string(image_name, ":", tag) : string(image_name, "@", digest)
    docker_read(["pull", ref])
    if digest === nothing
        digest = try
            repo_digest = chomp(docker_read(["image", "inspect", "--format", "{{index .RepoDigests 0}}", ref]))
            String(last(split(repo_digest, "@")))
        catch
            # e.g. locally-built images have no RepoDigests
            nothing
        end
    end
    return Image(image_name, tag, digest)
end

"""
    docker_images() -> Vector{Image}

Runs `docker images` and returns a vector of `Image` structs. Dangling images
(`<none>` repository or tag) are omitted.
"""
function docker_images()::Vector{Image}
    output = docker_read(["images", "--format", "{{.Repository}}:{{.Tag}}"])
    images = Image[]
    for line in split(output, "\n")
        isempty(line) && continue
        # rsplit: the repository may itself contain ':' (registry host port)
        name, tag = rsplit(line, ":"; limit=2)
        (name == "<none>" || tag == "<none>") && continue
        push!(images, Image(String(name), String(tag), nothing))
    end
    return images
end

"""
    docker_rm_image(image::Image; force::Bool=false) -> Bool

Runs `docker rmi [--force] <image>`. Returns `true` on success.
"""
function docker_rm_image(image::Image; force::Bool=false)::Bool
    args = ["rmi"]
    force && push!(args, "--force")
    # remove by name:tag (removing by digest would leave the tag behind)
    push!(args, string(image.name, ":", image.tag))
    docker_read(args)
    return true
end

"""
    docker_run(image::Image; name=nothing, ports=Dict{Int,Int}(),
               volumes=Dict{String,String}(), environment=Dict{String,String}(),
               command=nothing, detach::Bool=false) -> String

Runs `docker run` with the provided options and returns the container ID.
"""
function docker_run(image::Image; name=nothing, ports=Dict{Int,Int}(),
                    volumes=Dict{String,String}(), environment=Dict{String,String}(),
                    command=nothing, detach::Bool=false)::String
    # The container id is communicated via --cidfile: `docker run` only prints
    # the id on stdout when detached; in the foreground case stdout is the
    # container's own output.
    cidfile = tempname()
    args = ["run", "--cidfile", cidfile]
    if detach
        push!(args, "-d")
    end
    if name !== nothing
        push!(args, "--name", name)
    end
    # Add port mappings. A host port of 0 publishes the container port to an
    # ephemeral host port chosen by the OS.
    for (container_port, host_port) in ports
        if host_port == 0
            push!(args, "-p", string(container_port))
        else
            push!(args, "-p", string(host_port, ":", container_port))
        end
    end
    # Add volume mounts.
    for (container_path, host_path) in volumes
        push!(args, "-v", string(host_path, ":", container_path))
    end
    # Add environment variables. Only the *names* go on the command line
    # (visible in the host's process list); the values travel via the docker
    # CLI process environment, which `-e KEY` (without a value) forwards.
    for (key, _) in environment
        push!(args, "-e", key)
    end
    # Base image.
    push!(args, image_ref(image))
    # Append command if provided.
    if command !== nothing
        append!(args, command)
    end
    try
        docker_read(args; env=isempty(environment) ? nothing : environment)
        return String(chomp(read(cidfile, String)))
    finally
        rm(cidfile; force=true)
    end
end

"""
    docker_resolved_ports(container_id::String) -> Dict{Int, Int}

Queries the actual container port => host port mappings of a (running)
container via `docker inspect`, including ephemeral host ports assigned by
the OS.
"""
function docker_resolved_ports(container_id::String)::Dict{Int, Int}
    return _parse_network_ports(docker_inspect_container(container_id))
end

# Extract container port => host port mappings from a parsed `docker inspect`
# result's NetworkSettings.
function _parse_network_ports(info)::Dict{Int, Int}
    ports = Dict{Int, Int}()
    for (k, v) in something(get(get(info, "NetworkSettings", Dict{String, Any}()), "Ports", nothing), Dict{String, Any}())
        # key is like "8080/tcp"; value is null (or empty) for unpublished ports
        (v === nothing || isempty(v)) && continue
        container_port = tryparse(Int, first(split(k, "/")))
        host_port = tryparse(Int, string(get(v[1], "HostPort", "")))
        (container_port === nothing || host_port === nothing) && continue
        ports[container_port] = host_port
    end
    return ports
end

"""
    docker_ps(; all::Bool=false) -> Vector{String}

Runs `docker ps` (or `docker ps -a` if all is true) and returns a vector of container IDs.
"""
function docker_ps(; all::Bool=false)::Vector{String}
    args = ["ps", "--no-trunc", "--format", "{{.ID}}"]
    all && push!(args, "-a")
    output = docker_read(args)
    return String[line for line in split(output, "\n") if !isempty(line)]
end

"""
    docker_inspect_container(container_id::String) -> JSON object

Runs `docker inspect <container_id>` and returns the parsed JSON.
"""
function docker_inspect_container(container_id::String)
    output = docker_read(["inspect", container_id])
    return JSON.parse(output)[1]
end

"""
    docker_stop(container_id::String; timeout::Int=10) -> Bool

Runs `docker stop -t <timeout> <container_id>`. Returns true if successful.
"""
function docker_stop(container_id::String; timeout::Int=10)::Bool
    docker_read(["stop", "-t", string(timeout), container_id])
    return true
end

"""
    docker_kill(container_id::String; signal::Union{String,Int}="SIGKILL") -> Bool

Runs `docker kill --signal=<signal> <container_id>`. Returns true if successful.
"""
function docker_kill(container_id::String; signal::Union{String,Int}="SIGKILL")::Bool
    docker_read(["kill", "--signal=" * string(signal), container_id])
    return true
end

"""
    docker_rm(container_id::String; force::Bool=false) -> Bool

Runs `docker rm [--force] <container_id>`. Returns true if the container is removed.
"""
function docker_rm(container_id::String; force::Bool=false)::Bool
    args = ["rm"]
    force && push!(args, "--force")
    push!(args, container_id)
    docker_read(args)
    return true
end

"""
    docker_logs(container_id::String; follow::Bool=false, tail::Union{String,Int}="all") -> String

Runs `docker logs` with optional follow and tail parameters, returning the log output.
The container's stdout and stderr streams are merged in the returned string.
"""
function docker_logs(container_id::String; follow::Bool=false, tail::Union{String,Int}="all")::String
    args = ["logs"]
    follow && push!(args, "-f")
    push!(args, "--tail=" * string(tail), container_id)
    return docker_read(args; stderr_to_stdout=true)
end

"""
    docker_exec(container_id::String, exec_cmd::AbstractVector{<:AbstractString};
                detach::Bool=false, detach_keys::Union{Nothing,AbstractString}=nothing,
                env::Union{Nothing,AbstractDict{<:AbstractString,<:AbstractString}}=nothing,
                env_file::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}}=nothing,
                interactive::Bool=false, privileged::Bool=false, tty::Bool=false,
                user::Union{Nothing,AbstractString}=nothing,
                workdir::Union{Nothing,AbstractString}=nothing) -> String

Runs `docker exec` on the specified container. Returns the command's stdout as a string.
Throws a [`DockerError`](@ref) (carrying the exit code and captured stderr) if the
command exits with a non-zero status.
"""
function docker_exec(container_id::String, exec_cmd::AbstractVector{<:AbstractString};
                     detach::Bool=false, detach_keys::Union{Nothing,AbstractString}=nothing,
                     env::Union{Nothing,AbstractDict{<:AbstractString,<:AbstractString}}=nothing,
                     env_file::Union{Nothing,AbstractString,AbstractVector{<:AbstractString}}=nothing,
                     interactive::Bool=false, privileged::Bool=false, tty::Bool=false,
                     user::Union{Nothing,AbstractString}=nothing,
                     workdir::Union{Nothing,AbstractString}=nothing)::String
    args = ["exec"]
    detach && push!(args, "-d")
    interactive && push!(args, "-i")
    tty && push!(args, "-t")
    privileged && push!(args, "--privileged")
    if detach_keys !== nothing
        push!(args, "--detach-keys", String(detach_keys))
    end
    if user !== nothing
        push!(args, "-u", String(user))
    end
    if workdir !== nothing
        push!(args, "-w", String(workdir))
    end
    if env !== nothing
        # names only on the command line; values via the CLI's environment
        for (key, _) in env
            push!(args, "-e", String(key))
        end
    end
    if env_file !== nothing
        if env_file isa AbstractVector{<:AbstractString}
            for file in env_file
                push!(args, "--env-file", String(file))
            end
        else
            push!(args, "--env-file", String(env_file))
        end
    end
    push!(args, container_id)
    for part in exec_cmd
        push!(args, String(part))
    end
    env_map = env === nothing ? nothing :
        Dict{String, String}(String(k) => String(v) for (k, v) in env)
    return docker_read(args; env=env_map)
end

"""
    docker_start(container_id::String) -> Bool

Runs `docker start <container_id>`. Returns true if successful.
"""
function docker_start(container_id::String)::Bool
    docker_read(["start", container_id])
    return true
end

"""
    docker_restart(container_id::String; timeout::Int=10) -> Bool

Runs `docker restart -t <timeout> <container_id>`. Returns true if successful.
"""
function docker_restart(container_id::String; timeout::Int=10)::Bool
    docker_read(["restart", "-t", string(timeout), container_id])
    return true
end
