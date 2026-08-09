using Test, Harbor, Dates, Sockets

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
        @test_throws ArgumentError Harbor.normalize_wait_strategy((port=1, pattern="x"))
        @test_throws ArgumentError Harbor.normalize_wait_strategy(42)
    end

    @testset "http url parsing" begin
        @test Harbor._parse_http_url("http://127.0.0.1:8080/health") == ("127.0.0.1", 8080, "/health")
        @test Harbor._parse_http_url("http://localhost") == ("localhost", 80, "/")
        @test Harbor._parse_http_url("http://localhost:9/a/b?c=1") == ("localhost", 9, "/a/b?c=1")
        @test_throws ArgumentError Harbor._parse_http_url("https://localhost/x")
        @test_throws ArgumentError Harbor._parse_http_url("ftp://x")
    end

    # Pull an image and verify its properties.
    @testset "pull" begin
        img = Harbor.pull("alpine"; tag="latest")
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
        img = Harbor.pull("alpine"; tag="latest")
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
        img = Harbor.pull("alpine")
        cont = Harbor.run!(img; command=["echo", "hello-foreground"], detach=false)
        @test occursin(r"^[0-9a-f]{64}$", cont.id)
        @test cont.status == :exited
        @test occursin("hello-foreground", Harbor.logs(cont))
        Harbor.remove!(cont; force=true)
    end

    # ps must observe containers without ever managing (or destroying) them.
    @testset "ps observes but never manages containers" begin
        img = Harbor.pull("alpine")
        tmp = mktempdir()
        cont = Harbor.run!(img; name="harbor-ps-safety-test", command=["sleep", "60"],
                           volumes=Dict("/harbor-data" => tmp),
                           environment=Dict("HARBOR_PS_TEST" => "1"),
                           ports=Dict(9955 => 19955))
        try
            listed = Harbor.ps(; all=true)
            @test isa(listed, Vector{Harbor.Container})
            idx = findfirst(c -> c.id == cont.id, listed)
            @test idx !== nothing
            observed = listed[idx]
            @test observed.options.name == "harbor-ps-safety-test"
            @test observed.image.name == "alpine"
            @test observed.status == :running
            @test observed.created_at isa DateTime
            # volume binds parse (this used to crash ps entirely)
            @test haskey(observed.options.volumes, "/harbor-data")
            @test get(observed.options.environment, "HARBOR_PS_TEST", "") == "1"
            @test get(observed.options.ports, 9955, 0) == 19955
            @test get(observed.ports, 9955, 0) == 19955
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
        img = Harbor.pull("busybox")
        Harbor.with_container(img; command=["httpd", "-f", "-p", "8080"],
                              ports=Dict(8080 => 0), wait_timeout=30.0) do cont
            hp = Harbor.host_port(cont, 8080)
            @test hp > 0
            @test_throws ArgumentError Harbor.host_port(cont, 9999)
            # the ephemeral port really is reachable
            sock = connect("127.0.0.1", hp)
            write(sock, "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            response = read(sock, String)
            close(sock)
            @test occursin("404", first(split(response, "\r\n")))
        end
    end

    @testset "wait strategies" begin
        img = Harbor.pull("busybox")
        # HTTP wait strategy end-to-end (fixed host port so the URL is known upfront)
        Harbor.with_container(img; command=["httpd", "-f", "-p", "8080"],
                              ports=Dict(8080 => 18080),
                              wait_strategy=(url="http://127.0.0.1:18080/no-such-file", expected_status=404),
                              wait_timeout=30.0) do cont
            @test Harbor.host_port(cont, 8080) == 18080
        end

        # log wait matches both stdout and stderr, and accepts Regex
        result = Harbor.with_container("alpine";
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
        Harbor.with_container("alpine"; command=["sleep", "30"],
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

    @testset "wait timeout removes the container and reports logs" begin
        img = Harbor.pull("alpine")
        err = try
            Harbor.run!(img; name="harbor-wait-timeout-test",
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
        @test isempty(chomp(read(`docker ps -aq --filter name=harbor-wait-timeout-test`, String)))
    end

    @testset "with_container cleans up synchronously" begin
        img = Harbor.pull("alpine")
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
            Harbor.with_container(img; name="harbor-name-reuse-test", command=["sleep", "60"]) do cont
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

    @testset "environment values reach the container" begin
        Harbor.with_container("alpine"; command=["sleep", "30"],
                              environment=Dict("SECRET_VALUE" => "hunter2")) do cont
            @test chomp(Harbor.exec(cont, ["sh", "-c", "echo -n \$SECRET_VALUE"])) == "hunter2"
        end
    end

    @testset "show" begin
        img = Harbor.Image("alpine", "latest", nothing)
        opts = Harbor.RunOptions(; name="shown", ports=Dict(80 => 8080),
                                 volumes=Dict("/c" => "/h"), environment=Dict("A" => "b"),
                                 command=["echo", "hi"])
        cont = Harbor.Container("abc123", img, :running, now(), opts, Dict(80 => 8080))
        str = sprint(show, cont)
        @test occursin("abc123", str)
        @test occursin("shown", str)
        @test occursin("8080", str)
        # unmanaged handles have no finalizer side effects
        finalize(cont)
    end

    @testset "prune" begin
        img = Harbor.pull("alpine")
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

    # Last: removing the image (containers referencing it are gone by now).
    @testset "remove image" begin
        tmp_img = Harbor.pull("busybox"; tag="latest")
        @test Harbor.remove(tmp_img; force=true)
        @test !any(i -> i.name == "busybox" && i.tag == "latest", Harbor.images())
    end

end
