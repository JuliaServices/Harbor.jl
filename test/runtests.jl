using Test, Harbor

@testset "Harbor" begin

    # Pull an image and verify its properties.
    @testset "pull" begin
        img = Harbor.pull("alpine"; tag="latest")
        @test isa(img, Harbor.Image)
        @test img.name == "alpine"
        @test img.tag == "latest"
        
        # Ensure pulling with an empty image name throws an error.
        @test_throws ArgumentError Harbor.pull("")
    end

    # List images (we assume at least one image might be present after pull).
    @testset "images" begin
        imgs = Harbor.images()
        @test isa(imgs, Vector{Harbor.Image})
    end

    # Remove an image.
    @testset "remove image" begin
        # We pull a temporary image for removal.
        tmp_img = Harbor.pull("alpine"; tag="latest")
        removal_result = Harbor.remove(tmp_img; force=false)
        @test removal_result == true
    end

    # Run a container (here using alpine's "sleep" command).
    @testset "run! container" begin
        # Use alpine image.
        img = Harbor.pull("alpine"; tag="latest")
        # Run a container that sleeps for 5 seconds.
        cont = Harbor.run!(img; command=["sleep", "5"], ports=Dict{Int,Int}())
        @test isa(cont, Harbor.Container)
        @test cont.status == :running
        @test cont.image.name == "alpine"
        
        # Inspect the container.
        info = Harbor.inspect(cont)
        @test isa(info, Dict)
        
        # Check logs (they might be empty if nothing was output, but should be a String).
        logs_output = Harbor.logs(cont; follow=false, tail="100")
        @test isa(logs_output, String)
        exec_output = Harbor.exec(cont, ["sh", "-c", "echo -n hi"])
        @test chomp(exec_output) == "hi"
        env_output = Harbor.exec(cont, ["sh", "-c", "echo -n \$FOO"]; env=Dict("FOO" => "bar"))
        @test chomp(env_output) == "bar"
        workdir_output = Harbor.exec(cont, ["pwd"]; workdir="/tmp")
        @test chomp(workdir_output) == "/tmp"
        user_output = Harbor.exec(cont, ["id", "-u"]; user="root")
        @test chomp(user_output) == "0"
        
        # Stop the container.
        cont = Harbor.stop!(cont; timeout=5)
        @test cont.status == :stopped
        
        # Remove the container.
        removal = Harbor.remove!(cont)
        @test removal == true
    end

    # Test ps function.
    @testset "ps" begin
        containers_list = Harbor.ps(; all=true)
        @test isa(containers_list, Vector{Harbor.Container})
    end

    # Test with_container block.
    @testset "with_container" begin
        img = Harbor.pull("alpine"; tag="latest")
        result = Harbor.with_container(img; command=["sleep", "1"]) do cont
            @test cont.status == :running
            # Return a simple result.
            "done"
        end
        @test result == "done"
        result = Harbor.with_container("alpine"; command=["sleep", "1"]) do cont
            @test cont.status == :running
            # Return a simple result.
            "done"
        end
        @test result == "done"
    end

end
