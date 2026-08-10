using Test, Harbor, Dates, Sockets

# Names are unique per test process. A test run must never delete a container
# merely because another user or project chose the same fixed name.
const TEST_RUN_SUFFIX = string(getpid(), "-", time_ns())
const PS_SAFETY_NAME = "harbor-ps-safety-" * TEST_RUN_SUFFIX
const WAIT_TIMEOUT_NAME = "harbor-wait-timeout-" * TEST_RUN_SUFFIX
const NAME_REUSE_NAME = "harbor-name-reuse-" * TEST_RUN_SUFFIX

# Some testsets are host-destructive beyond this suite's own artifacts:
# prune() removes ALL Harbor-labeled containers on the machine (other
# projects' included), and the image-removal tests delete the local alpine
# and busybox images. Run those only on CI.
const IS_CI = get(ENV, "CI", "") == "true"

# An OS-assigned free host port (closed again immediately — a small race, but
# far less collision-prone than hardcoded ports on shared CI runners).
function free_port()
    server = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(server)[2])
    close(server)
    return port
end

# Shared test images, pulled once (repeated pulls hammer Docker Hub's
# anonymous rate limits on CI).
const ALPINE = Harbor.pull("alpine"; tag="latest")
const BUSYBOX = Harbor.pull("busybox"; tag="latest")

@testset "Harbor" begin

    # Pure parsing tests (no docker required).
    @testset "image reference parsing" begin
        @test Harbor._split_ref("alpine") == ("alpine", nothing, nothing)
        @test Harbor._split_ref("alpine:3.19") == ("alpine", "3.19", nothing)
        @test Harbor._split_ref("repo/img") == ("repo/img", nothing, nothing)
        @test Harbor._split_ref("localhost:5000/img") == ("localhost:5000/img", nothing, nothing)
        @test Harbor._split_ref("localhost:5000/img:tag") == ("localhost:5000/img", "tag", nothing)
        @test Harbor._split_ref("alpine@sha256:abc") == ("alpine", nothing, "sha256:abc")
        @test Harbor._split_ref("repo/img:1.0@sha256:abc") == ("repo/img", "1.0", "sha256:abc")
        @test_throws ArgumentError Harbor._check_ref("@sha256:abc", nothing)
        @test_throws ArgumentError Harbor._check_ref("alpine@", nothing)
        @test_throws ArgumentError Harbor._check_ref("alpine:", nothing)
        @test_throws ArgumentError Harbor._check_ref("a@@sha256:abc", nothing)
        @test_throws ArgumentError Harbor._check_ref("alpine@sha256:abc", "latest")
    end

    @testset "wait strategy normalization" begin
        @test Harbor.normalize_wait_strategy(nothing) === nothing
        @test Harbor.normalize_wait_strategy((port=8080,)) isa Harbor.WaitForPort
        @test Harbor.normalize_wait_strategy((port=Int32(8080),)).port == 8080
        @test Harbor.normalize_wait_strategy((pattern="ready",)) isa Harbor.WaitForLog
        @test Harbor.normalize_wait_strategy((pattern=r"ready",)) isa Harbor.WaitForLog
        # field order must not matter
        @test Harbor.normalize_wait_strategy((expected_status=200, url="http://x")) isa Harbor.WaitForHTTP
        @test Harbor.normalize_wait_strategy((healthy=true,)) isa Harbor.WaitForHealthy
        @test Harbor.normalize_wait_strategy(c -> true) isa Harbor.CustomWait
        @test_throws ArgumentError Harbor.normalize_wait_strategy((bogus=1,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((pattern=5,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((port="80",))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((healthy=1,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((healthy=false,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((port=true,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((port=0,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((port=65536,))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((url="http://x", expected_status=true))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((url="http://x", expected_status=99))
        @test_throws ArgumentError Harbor.normalize_wait_strategy((port=1, pattern="x"))
        @test_throws ArgumentError Harbor.normalize_wait_strategy(42)
    end

    @testset "docker timestamp parsing" begin
        @test Harbor._parse_docker_timestamp("2026-08-09T12:34:56.789123456Z") == DateTime(2026, 8, 9, 12, 34, 56, 789)
        # docker trims trailing fractional zeros
        @test Harbor._parse_docker_timestamp("2026-08-09T12:34:56.78Z") == DateTime(2026, 8, 9, 12, 34, 56, 780)
        @test Harbor._parse_docker_timestamp("2026-08-09T12:34:56Z") == DateTime(2026, 8, 9, 12, 34, 56)
        @test Harbor._parse_docker_timestamp("garbage") === nothing
    end

    @testset "structured mount parsing" begin
        info = Dict("Mounts" => [
            Dict("Type" => "bind", "Source" => raw"C:\host\data",
                 "Destination" => raw"C:\container\data"),
            Dict("Type" => "volume", "Name" => "named-volume",
                 "Source" => "/var/lib/docker/volumes/named-volume/_data",
                 "Destination" => "/data"),
        ])
        @test Harbor._parse_mount_volumes(info) == Dict(
            raw"C:\container\data" => raw"C:\host\data",
            "/data" => "named-volume",
        )
    end

    @testset "http url parsing" begin
        @test Harbor._parse_http_url("http://127.0.0.1:8080/health") == ("127.0.0.1", 8080, "/health")
        @test Harbor._parse_http_url("http://localhost") == ("localhost", 80, "/")
        @test Harbor._parse_http_url("http://localhost:9/a/b?c=1") == ("localhost", 9, "/a/b?c=1")
        @test_throws ArgumentError Harbor._parse_http_url("https://localhost/x")
        @test_throws ArgumentError Harbor._parse_http_url("ftp://x")
        @test_throws ArgumentError Harbor._parse_http_url("http://localhost:65536/")
    end

    @testset "HTTP wait reads only a bounded status line" begin
        function probe_server(response::Union{Nothing, String}, probe_timeout::Float64)
            server = listen(ip"127.0.0.1", 0)
            port = Int(getsockname(server)[2])
            release = Channel{Nothing}(1)
            server_task = errormonitor(@async begin
                sock = accept(server)
                response === nothing || write(sock, response)
                take!(release)
                close(sock)
            end)
            strategy = Harbor.normalize_wait_strategy((url="http://127.0.0.1:$port/", expected_status=200))
            opts = Harbor.RunOptions(; wait_strategy=strategy)
            container = Harbor.Container("probe", Harbor.Image("none"), :running,
                                         now(), opts)
            probe = errormonitor(@async Harbor.check_wait_strategy(strategy, container;
                                                                    timeout=probe_timeout))
            status = timedwait(() -> istaskdone(probe), 1.0)
            put!(release, nothing)
            close(server)
            wait(server_task)
            return status, fetch(probe)
        end
        status, ready = probe_server("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 0.2)
        @test status === :ok
        @test ready
        status, ready = probe_server(nothing, 0.2)
        @test status === :ok
        @test !ready
    end

    @testset "port and wait timing validation" begin
        @test Harbor._normalize_ports(Dict(80 => 0)) == Dict(80 => 0)
        @test_throws ArgumentError Harbor._normalize_ports(Dict(true => 0))
        @test_throws ArgumentError Harbor._normalize_ports(Dict(0 => 0))
        @test_throws ArgumentError Harbor._normalize_ports(Dict(80 => -1))
        @test_throws ArgumentError Harbor._normalize_ports(Dict(80 => 65536))
        @test Harbor._validate_wait_timing(0.0, 0.1) === nothing
        @test_throws ArgumentError Harbor._validate_wait_timing(-1.0, 0.1)
        @test_throws ArgumentError Harbor._validate_wait_timing(Inf, 0.1)
        @test_throws ArgumentError Harbor._validate_wait_timing(1.0, 0.0)
        @test_throws ArgumentError Harbor._validate_wait_timing(1.0, NaN)
    end

    # Pull an image and verify its properties.
    @testset "pull" begin
        img = ALPINE
        @test isa(img, Harbor.Image)
        @test img.name == "alpine"
        @test img.tag == "latest"
        # digest is recorded for registry pulls
        @test img.digest !== nothing && startswith(img.digest, "sha256:")

        # tags may be embedded in the reference
        img2 = Harbor.pull("alpine:latest")
        @test img2.name == "alpine" && img2.tag == "latest"

        @test_throws ArgumentError Harbor.pull("")
        @test_throws ArgumentError Harbor.pull("alpine:3.19"; tag="latest")
        @test_throws Harbor.DockerError Harbor.pull("harbor-jl-test/definitely-does-not-exist")
    end

    @testset "images" begin
        imgs = Harbor.images()
        @test isa(imgs, Vector{Harbor.Image})
        @test any(i -> i.name == "alpine" && i.tag == "latest", imgs)
    end

    # Run a container and exercise the whole lifecycle.
    @testset "run!, exec, logs, lifecycle" begin
        img = ALPINE
        cont = Harbor.run!(img; command=["sleep", "60"])
        @test isa(cont, Harbor.Container)
        @test cont.status == :running
        @test cont.image.name == "alpine"
        @test occursin(r"^[0-9a-f]{64}$", cont.id)
        @test Harbor.is_running(cont)

        info = Harbor.inspect(cont)
        @test isa(info, Dict)

        logs_output = Harbor.logs(cont; follow=false, tail="100")
        @test isa(logs_output, String)

        @test chomp(Harbor.exec(cont, ["sh", "-c", "echo -n hi"])) == "hi"
        @test chomp(Harbor.exec(cont, ["sh", "-c", "echo -n \$FOO"]; env=Dict("FOO" => "bar"))) == "bar"
        @test chomp(Harbor.exec(cont, ["pwd"]; workdir="/tmp")) == "/tmp"
        @test chomp(Harbor.exec(cont, ["id", "-u"]; user="root")) == "0"

        # a failing exec throws a DockerError carrying exit code and stderr
        err = try
            Harbor.exec(cont, ["sh", "-c", "echo oops >&2; exit 3"])
            nothing
        catch e
            e
        end
        @test err isa Harbor.DockerError
        @test err.exitcode == 3
        @test occursin("oops", err.stderr)
        @test occursin("oops", sprint(showerror, err))

        # stop / start / restart / kill
        cont = Harbor.stop!(cont; timeout=1)
        @test cont.status == :stopped
        @test !Harbor.is_running(cont)
        Harbor.start!(cont)
        @test Harbor.is_running(cont)
        Harbor.restart!(cont; timeout=1)
        @test Harbor.is_running(cont)
        # a non-fatal signal must not mark the container exited
        Harbor.kill!(cont; signal="SIGUSR1")
        @test cont.status == :running
        @test Harbor.is_running(cont)
        Harbor.kill!(cont)
        @test !Harbor.is_running(cont)
        @test cont.status == :exited

        # remove
        @test Harbor.remove!(cont; force=true)
        @test cont.status == :removed
        @test !(cont.id in Harbor.docker_ps(all=true))
        @test !Harbor.is_running(cont)
    end

    @testset "run! with detach=false records the real container id" begin
        img = ALPINE
        cont = Harbor.run!(img; command=["echo", "hello-foreground"], detach=false)
        @test occursin(r"^[0-9a-f]{64}$", cont.id)
        @test cont.status == :exited
        @test occursin("hello-foreground", Harbor.logs(cont))
        Harbor.remove!(cont; force=true)
    end

    # ps must observe containers without ever managing (or destroying) them.
    @testset "ps observes but never manages containers" begin
        img = ALPINE
        tmp = mktempdir()
        hp = free_port()
        cont = Harbor.run!(img; name=PS_SAFETY_NAME, command=["sleep", "60"],
                           volumes=Dict("/harbor-data" => tmp),
                           environment=Dict("HARBOR_PS_TEST" => "1"),
                           ports=Dict(9955 => hp), wait_strategy=c -> true)
        try
            listed = Harbor.ps(; all=true)
            @test isa(listed, Vector{Harbor.Container})
            idx = findfirst(c -> c.id == cont.id, listed)
            @test idx !== nothing
            observed = listed[idx]
            @test observed.options.name == PS_SAFETY_NAME
            @test observed.image.name == "alpine"
            @test observed.status == :running
            @test observed.created_at isa DateTime
            # volume binds parse (this used to crash ps entirely)
            @test haskey(observed.options.volumes, "/harbor-data")
            @test get(observed.options.environment, "HARBOR_PS_TEST", "") == "1"
            @test get(observed.options.ports, 9955, 0) == hp
            @test get(observed.ports, 9955, 0) == hp
            # finalizing observed handles must NOT touch the real containers
            foreach(finalize, listed)
            GC.gc(); sleep(1)
            @test cont.id in Harbor.docker_ps(all=true)
            @test Harbor.is_running(cont)
        finally
            Harbor.cleanup!(cont)
        end
    end

    @testset "ephemeral ports and host_port" begin
        img = BUSYBOX
        Harbor.with_container(img; command=["httpd", "-f", "-p", "8080"],
                              ports=Dict(8080 => 0), wait_timeout=30.0) do cont
            hp = Harbor.host_port(cont, 8080)
            @test hp > 0
            @test_throws ArgumentError Harbor.host_port(cont, 9999)
            @test_throws ArgumentError Harbor.host_port(cont, true)
            # the ephemeral port really is reachable
            sock = connect("127.0.0.1", hp)
            write(sock, "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            response = read(sock, String)
            close(sock)
            @test occursin("404", first(split(response, "\r\n")))
        end
    end

    @testset "wait strategies" begin
        img = BUSYBOX
        # HTTP wait strategy end-to-end (the URL must be known up front, so pick a
        # free host port dynamically instead of hardcoding one)
        hp = free_port()
        Harbor.with_container(img; command=["httpd", "-f", "-p", "8080"],
                              ports=Dict(8080 => hp),
                              wait_strategy=(url="http://127.0.0.1:$hp/no-such-file", expected_status=404),
                              wait_timeout=30.0) do cont
            @test Harbor.host_port(cont, 8080) == hp
        end

        # log wait matches both stdout and stderr, and accepts Regex
        result = Harbor.with_container(ALPINE;
            command=["sh", "-c", "echo stdout-ready; echo stderr-ready >&2; sleep 30"],
            wait_strategy=(pattern=r"stderr-ready",),
            wait_timeout=15.0) do cont
            logs_output = Harbor.logs(cont; follow=false, tail="all")
            @test occursin("stdout-ready", logs_output)
            @test occursin("stderr-ready", logs_output)
            "done"
        end
        @test result == "done"

        # a bare function is a custom wait strategy
        checked = Ref(false)
        Harbor.with_container(ALPINE; command=["sleep", "30"],
                              wait_strategy=c -> (checked[] = true)) do cont
            @test checked[]
        end

        # (healthy=true,) errors immediately for images without a HEALTHCHECK
        err = try
            Harbor.run!(img; command=["sleep", "30"], wait_strategy=(healthy=true,))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("HEALTHCHECK", sprint(showerror, err))
    end

    @testset "port wait is not fooled by docker's userland proxy" begin
        # nothing listens on 8080 inside the container; docker's proxy still
        # accepts TCP connections on the published host port
        err = try
            Harbor.run!(ALPINE; command=["sleep", "30"], ports=Dict(8080 => 0),
                        wait_timeout=3.0, wait_interval=0.5)
            nothing
        catch e
            e
        end
        @test err isa Harbor.WaitTimeoutError
    end

    @testset "foreground non-zero exit returns the handle, including 125" begin
        before = length(Harbor.docker_ps(all=true, label=Harbor.HARBOR_LABEL * "=true"))
        for exit_code in (7, 125)
            cont = Harbor.run!(ALPINE;
                command=["sh", "-c", "echo failing-output-$exit_code; exit $exit_code"],
                detach=false)
            @test cont.status == :exited
            @test occursin("failing-output-$exit_code", Harbor.logs(cont))
            info = Harbor.inspect(cont)
            @test get(get(info, "State", Dict{String, Any}()), "ExitCode", -1) == exit_code
            Harbor.remove!(cont; force=true)
        end
        # foreground + ports: the auto port-wait must not fire for exited runs
        cont2 = Harbor.run!(ALPINE; command=["true"], detach=false, ports=Dict(8080 => 0))
        @test cont2.status == :exited
        Harbor.remove!(cont2; force=true)
        @test length(Harbor.docker_ps(all=true, label=Harbor.HARBOR_LABEL * "=true")) == before
    end

    @testset "wait aborts as soon as the container exits" begin
        before = time()
        err = try
            Harbor.run!(ALPINE; command=["sh", "-c", "echo died-early; exit 1"],
                        wait_strategy=(pattern="never-going-to-appear",),
                        wait_timeout=60.0, wait_interval=0.5)
            nothing
        catch e
            e
        end
        @test err isa Harbor.ContainerExitedError
        @test occursin("died-early", sprint(showerror, err))
        @test time() - before < 30  # nowhere near the 60s timeout
    end

    @testset "wait timeout removes the container and reports logs" begin
        img = ALPINE
        err = try
            Harbor.run!(img; name=WAIT_TIMEOUT_NAME,
                        command=["sh", "-c", "echo some-log-line; sleep 60"],
                        wait_strategy=(pattern="never-going-to-appear",),
                        wait_timeout=3.0, wait_interval=0.5)
            nothing
        catch e
            e
        end
        @test err isa Harbor.WaitTimeoutError
        msg = sprint(showerror, err)
        @test occursin("never-going-to-appear", msg)
        @test occursin("some-log-line", msg)  # container logs included
        # the container was synchronously removed; its name is free again
        @test isempty(chomp(read(`docker ps -aq --filter name=$WAIT_TIMEOUT_NAME`, String)))
    end

    @testset "with_container cleans up synchronously" begin
        img = ALPINE
        local cid
        result = Harbor.with_container(img; command=["sleep", "60"]) do cont
            cid = cont.id
            @test cont.status == :running
            "done"
        end
        @test result == "done"
        # gone immediately — no async cleanup race
        @test !(cid in Harbor.docker_ps(all=true))

        # a fixed name is immediately reusable
        for _ in 1:2
            Harbor.with_container(img; name=NAME_REUSE_NAME, command=["sleep", "60"]) do cont
                @test Harbor.is_running(cont)
            end
        end

        # the error path also cleans up, and rethrows the original error
        local cid2
        @test_throws ErrorException Harbor.with_container(img; command=["sleep", "60"],
                                                          container_logs_on_error=true) do cont
            cid2 = cont.id
            error("boom")
        end
        @test !(cid2 in Harbor.docker_ps(all=true))

        # string-image form works (and supports name:tag references)
        result = Harbor.with_container("alpine:latest"; command=["sleep", "5"]) do cont
            @test cont.status == :running
            "done"
        end
        @test result == "done"
    end

    @testset "environment values reach the container without changing the docker CLI" begin
        Harbor.with_container(ALPINE; command=["sleep", "30"],
                              environment=Dict("SECRET_VALUE" => "hunter2",
                                               "DOCKER_HOST" => "container-only")) do cont
            @test chomp(Harbor.exec(cont, ["sh", "-c", "echo -n \$SECRET_VALUE"])) == "hunter2"
            @test chomp(Harbor.exec(cont, ["sh", "-c", "echo -n \$DOCKER_HOST"])) == "container-only"
            @test chomp(Harbor.exec(cont, ["sh", "-c", "echo -n \$DOCKER_HOST"];
                                    env=Dict("DOCKER_HOST" => "exec-only"))) == "exec-only"
        end
        @test_throws ArgumentError Harbor.run!(ALPINE; command=["true"],
                                               environment=Dict("MULTILINE" => "a\nb"))
    end

    @testset "show" begin
        img = Harbor.Image("alpine", "latest", nothing)
        opts = Harbor.RunOptions(; name="shown", ports=Dict(80 => 8080),
                                 volumes=Dict("/c" => "/h"),
                                 environment=Dict("PASSWORD" => "unique-secret-value"),
                                 command=["echo", "hi"])
        cont = Harbor.Container("abc123", img, :running, now(), opts, Dict(80 => 8080))
        str = sprint(show, cont)
        @test occursin("abc123", str)
        @test occursin("shown", str)
        @test occursin("8080", str)
        @test occursin("PASSWORD", str)
        @test occursin("<redacted>", str)
        @test !occursin("unique-secret-value", str)
        # unmanaged handles have no finalizer side effects
        finalize(cont)
    end

    @testset "inspect errors preserve daemon failures" begin
        missing = Harbor.DockerError(`docker inspect missing`, 1,
                                     "Error: No such object: missing")
        daemon = Harbor.DockerError(`docker inspect missing`, 1,
                                    "Cannot connect to the Docker daemon")
        @test Harbor._is_missing_container_error(missing)
        @test !Harbor._is_missing_container_error(daemon)
        fake = Harbor.Container("missing", Harbor.Image("alpine"), :removed,
                                now(), Harbor.RunOptions())
        @test !Harbor.is_running(fake)
        Harbor.cleanup!(fake)
        @test fake.cleaned_up
        @test fake.status == :removed
        failed_cleanup = Harbor.Container("missing", Harbor.Image("alpine"),
                                          :running, now(), Harbor.RunOptions())
        missing_socket = "unix://" * joinpath(tempdir(),
                                               "harbor-missing-$TEST_RUN_SUFFIX.sock")
        withenv("DOCKER_HOST" => missing_socket) do
            @test_throws Harbor.DockerError Harbor.is_running(failed_cleanup)
            @test Harbor.cleanup!(failed_cleanup) === nothing
            @test !failed_cleanup.cleaned_up
            @test failed_cleanup.status == :running
            @test_throws Harbor.DockerError Harbor.cleanup!(failed_cleanup;
                                                             throw_errors=true)
        end
    end

    if !IS_CI
        @info "Skipping prune and image-removal testsets outside CI (they remove ALL Harbor-labeled containers and the local alpine/busybox images)"
    end

    IS_CI && @testset "prune" begin
        img = ALPINE
        c1 = Harbor.run!(img; command=["sleep", "60"])
        c2 = Harbor.run!(img; command=["sleep", "60"])
        n = Harbor.prune()
        @test n >= 2
        @test !(c1.id in Harbor.docker_ps(all=true))
        @test !(c2.id in Harbor.docker_ps(all=true))
        # mark the handles cleaned so their finalizers stay quiet
        Harbor.cleanup!(c1)
        Harbor.cleanup!(c2)
    end

    # Last: removing images (containers referencing them are gone by now).
    IS_CI && @testset "remove image" begin
        @test Harbor.remove(BUSYBOX; force=true)
        @test !any(i -> i.name == "busybox" && i.tag == "latest", Harbor.images())
    end

    IS_CI && @testset "digest-pinned pull" begin
        @test ALPINE.digest !== nothing
        pinned = Harbor.pull("alpine@" * ALPINE.digest)
        @test pinned.digest == ALPINE.digest
        @test pinned.tag == ""  # digest pulls create no local tag
        # docker removes a digest-referenced image together with all its tags
        @test Harbor.remove(pinned)
        @test !any(i -> i.name == "alpine" && i.tag == "latest", Harbor.images())
    end

end
