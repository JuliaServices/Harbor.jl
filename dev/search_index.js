var documenterSearchIndex = {"docs":
[{"location":"#Harbor","page":"Harbor","title":"Harbor","text":"","category":"section"},{"location":"","page":"Harbor","title":"Harbor","text":"Harbor Julia package repo.","category":"page"},{"location":"","page":"Harbor","title":"Harbor","text":"Modules = [Harbor]","category":"page"},{"location":"#Harbor.docker_exec-Tuple{String, Vector{String}}","page":"Harbor","title":"Harbor.docker_exec","text":"docker_exec(container_id::String, exec_cmd::Vector{String}; detach::Bool=false) -> String\n\nRuns docker exec on the specified container. Returns the command output as a string.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_images-Tuple{}","page":"Harbor","title":"Harbor.docker_images","text":"docker_images() -> Vector{Image}\n\nRuns docker images and returns a vector of Image structs.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_inspect_container-Tuple{String}","page":"Harbor","title":"Harbor.docker_inspect_container","text":"docker_inspect_container(container_id::String) -> Dict\n\nRuns docker inspect <container_id> and returns the parsed JSON as a Dict.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_kill-Tuple{String}","page":"Harbor","title":"Harbor.docker_kill","text":"docker_kill(container_id::String; signal::Union{String,Int}=\"SIGTERM\") -> Bool\n\nRuns docker kill --signal=<signal> <container_id>. Returns true if successful.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_logs-Tuple{String}","page":"Harbor","title":"Harbor.docker_logs","text":"docker_logs(container_id::String; follow::Bool=false, tail::Union{String,Int}=\"all\") -> String\n\nRuns docker logs with optional follow and tail parameters, returning the log output.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_ps-Tuple{}","page":"Harbor","title":"Harbor.docker_ps","text":"docker_ps(; all::Bool=false) -> Vector{String}\n\nRuns docker ps (or docker ps -a if all is true) and returns a vector of container IDs.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_pull-Tuple{String}","page":"Harbor","title":"Harbor.docker_pull","text":"docker_pull(image_name::String; tag::String=\"latest\") -> Image\n\nRuns docker pull <image_name>:<tag>. On success, returns an Image struct.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_restart-Tuple{String}","page":"Harbor","title":"Harbor.docker_restart","text":"docker_restart(container_id::String; timeout::Int=10) -> Bool\n\nRuns docker restart --time=<timeout> <container_id>. Returns true if successful.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_rm-Tuple{String}","page":"Harbor","title":"Harbor.docker_rm","text":"docker_rm(container_id::String; force::Bool=false) -> Bool\n\nRuns docker rm [--force] <container_id>. Returns true if the container is removed.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_rm_image-Tuple{Harbor.Image}","page":"Harbor","title":"Harbor.docker_rm_image","text":"docker_rm_image(image::Image; force::Bool=false) -> Bool\n\nRuns docker rmi [--force] <image>. Returns true on success.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_run-Tuple{Harbor.Image}","page":"Harbor","title":"Harbor.docker_run","text":"docker_run(image::Image; name=nothing, ports=Dict{Int,Int}(),\n           volumes=Dict{String,String}(), environment=Dict{String,String}(),\n           command=nothing, detach::Bool=false) -> String\n\nRuns docker run with the provided options and returns the container ID.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_start-Tuple{String}","page":"Harbor","title":"Harbor.docker_start","text":"docker_start(container_id::String) -> Bool\n\nRuns docker start <container_id>. Returns true if successful.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.docker_stop-Tuple{String}","page":"Harbor","title":"Harbor.docker_stop","text":"docker_stop(container_id::String; timeout::Int=10) -> Bool\n\nRuns docker stop --time=<timeout> <container_id>. Returns true if successful.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.images-Tuple{}","page":"Harbor","title":"Harbor.images","text":"images() -> Vector{Image}\n\nRetrieves a list of available images.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.inspect-Tuple{Harbor.Container}","page":"Harbor","title":"Harbor.inspect","text":"inspect(container::Container) -> Dict\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.logs-Tuple{Harbor.Container}","page":"Harbor","title":"Harbor.logs","text":"logs(container::Container) -> String\n\nRetrieves the logs for the specified container.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.ps-Tuple{}","page":"Harbor","title":"Harbor.ps","text":"ps(; all::Bool=true) -> Vector{Container}\n\nLists containers. If all is true, lists all containers; otherwise, only running ones.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.pull-Tuple{String}","page":"Harbor","title":"Harbor.pull","text":"pull(image::String; tag::String=\"latest\") -> Image\n\nPulls an image from a registry and returns an Image instance.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.remove!-Tuple{Harbor.Container}","page":"Harbor","title":"Harbor.remove!","text":"remove!(container::Container) -> Bool\n\nRemoves a container from the system. Returns true if successful.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.remove-Tuple{Harbor.Image}","page":"Harbor","title":"Harbor.remove","text":"remove(image::Image; force::Bool=false) -> Bool\n\nRemoves the specified image.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.run!-Tuple{Harbor.Image}","page":"Harbor","title":"Harbor.run!","text":"run!(image::Image; name=nothing, ports=Dict{Int,Int}(),                volumes=Dict{String,String}(), environment=Dict{String,String}(),                command=nothing, detach::Bool=false) -> Container\n\nStarts a container from the provided Image with the specified options. Returns a Container instance reflecting the running state.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.stop!-Tuple{Harbor.Container}","page":"Harbor","title":"Harbor.stop!","text":"stop!(container::Container; timeout::Int=10) -> Container\n\nGracefully stops a running container. Returns the Container with a new status.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.wait_for-Tuple{Harbor.Container}","page":"Harbor","title":"Harbor.wait_for","text":"wait_for(container::Container)\n\nWaits until the given strategy condition is met or the timeout expires. Throws an error if the wait condition isn't satisfied in time.\n\n\n\n\n\n","category":"method"},{"location":"#Harbor.with_container-Tuple{Function, Harbor.Image}","page":"Harbor","title":"Harbor.with_container","text":"with_container(image::Image; kw...) do container     # operations on container end\n\nRuns a container with the specified image and keyword options. The container is automatically stopped and removed after the block completes (even if an error occurs).\n\n\n\n\n\n","category":"method"}]
}
