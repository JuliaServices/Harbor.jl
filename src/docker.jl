"""
    docker_pull(image_name::String; tag::String="latest") -> Image

Runs `docker pull <image_name>:<tag>`. On success, returns an `Image` struct.
"""
function docker_pull(image_name::String; tag::String="latest")::Image
    image_ref = string(image_name, ":", tag)
    cmd = Cmd(["docker", "pull", image_ref])
    run(cmd)  # Throws on non-zero status.
    return Image(image_name, tag, nothing)
end

"""
    docker_images() -> Vector{Image}

Runs `docker images` and returns a vector of `Image` structs.
"""
function docker_images()::Vector{Image}
    cmd = Cmd(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"])
    output = read(cmd, String)
    images = String[]
    for line in split(output, "\n")
        if !isempty(line)
            push!(images, line)
        end
    end
    # Parse each line into an Image.
    return [let parts = split(img, ":")
            Image(parts[1], parts[2], nothing)
          end for img in images]
end

"""
    docker_rm_image(image::Image; force::Bool=false) -> Bool

Runs `docker rmi [--force] <image>`. Returns `true` on success.
"""
function docker_rm_image(image::Image; force::Bool=false)::Bool
    image_ref = string(image.name, ":", image.tag)
    if force
        cmd = Cmd(["docker", "rmi", "--force", image_ref])
    else
        cmd = Cmd(["docker", "rmi", image_ref])
    end
    run(cmd)
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
    args = String[]
    if detach
        push!(args, "-d")
    end
    if name !== nothing
        push!(args, "--name", name)
    end
    # Add port mappings.
    for (container_port, host_port) in ports
        push!(args, "-p", string(host_port, ":", container_port))
    end
    # Add volume mounts.
    for (container_path, host_path) in volumes
        push!(args, "-v", string(host_path, ":", container_path))
    end
    # Add environment variables.
    for (key, val) in environment
        push!(args, "-e", string(key, "=", val))
    end
    # Base image.
    image_ref = string(image.name, ":", image.tag)
    push!(args, image_ref)
    # Append command if provided.
    if command !== nothing
        append!(args, command)
    end
    # Build command using Cmd constructor.
    cmd = Cmd(vcat(["docker", "run"], args))
    container_id = chomp(read(cmd, String))
    return container_id
end

"""
    docker_ps(; all::Bool=false) -> Vector{String}

Runs `docker ps` (or `docker ps -a` if all is true) and returns a vector of container IDs.
"""
function docker_ps(; all::Bool=false)::Vector{String}
    if all
        cmd = Cmd(["docker", "ps", "-a", "--format", "{{.ID}}"])
    else
        cmd = Cmd(["docker", "ps", "--format", "{{.ID}}"])
    end
    output = read(cmd, String)
    return [line for line in split(output, "\n") if !isempty(line)]
end

"""
    docker_inspect_container(container_id::String) -> JSON object

Runs `docker inspect <container_id>` and returns the parsed JSON.
"""
function docker_inspect_container(container_id::String)
    cmd = Cmd(["docker", "inspect", container_id])
    output = read(cmd, String)
    ret = JSON.parse(output)
    return ret[1]
end

"""
    docker_stop(container_id::String; timeout::Int=10) -> Bool

Runs `docker stop --time=<timeout> <container_id>`. Returns true if successful.
"""
function docker_stop(container_id::String; timeout::Int=10)::Bool
    cmd = Cmd(["docker", "stop", "--time=" * string(timeout), container_id])
    run(cmd)
    return true
end

"""
    docker_kill(container_id::String; signal::Union{String,Int}="SIGTERM") -> Bool

Runs `docker kill --signal=<signal> <container_id>`. Returns true if successful.
"""
function docker_kill(container_id::String; signal::Union{String,Int}="SIGTERM")::Bool
    cmd = Cmd(["docker", "kill", "--signal=" * string(signal), container_id])
    run(cmd)
    return true
end

"""
    docker_rm(container_id::String; force::Bool=false) -> Bool

Runs `docker rm [--force] <container_id>`. Returns true if the container is removed.
"""
function docker_rm(container_id::String; force::Bool=false)::Bool
    if force
        cmd = Cmd(["docker", "rm", "--force", container_id])
    else
        cmd = Cmd(["docker", "rm", container_id])
    end
    run(cmd)
    return true
end

"""
    docker_logs(container_id::String; follow::Bool=false, tail::Union{String,Int}="all") -> String

Runs `docker logs` with optional follow and tail parameters, returning the log output.
"""
function docker_logs(container_id::String; follow::Bool=false, tail::Union{String,Int}="all")::String
    args = String[]
    if follow
        push!(args, "-f")
    end
    push!(args, "--tail=" * string(tail))
    push!(args, container_id)
    cmd = Cmd(vcat(["docker", "logs"], args))
    return read(cmd, String)
end

"""
    docker_exec(container_id::String, exec_cmd::Vector{String}; detach::Bool=false) -> String

Runs `docker exec` on the specified container. Returns the command output as a string.
"""
function docker_exec(container_id::String, exec_cmd::Vector{String}; detach::Bool=false)::String
    args = detach ? ["-d"] : String[]
    push!(args, container_id)
    append!(args, exec_cmd)
    cmd = Cmd(vcat(["docker", "exec"], args))
    return read(cmd, String)
end

"""
    docker_start(container_id::String) -> Bool

Runs `docker start <container_id>`. Returns true if successful.
"""
function docker_start(container_id::String)::Bool
    cmd = Cmd(["docker", "start", container_id])
    run(cmd)
    return true
end

"""
    docker_restart(container_id::String; timeout::Int=10) -> Bool

Runs `docker restart --time=<timeout> <container_id>`. Returns true if successful.
"""
function docker_restart(container_id::String; timeout::Int=10)::Bool
    cmd = Cmd(["docker", "restart", "--time=" * string(timeout), container_id])
    run(cmd)
    return true
end
