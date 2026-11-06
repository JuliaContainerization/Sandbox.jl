using Test, Sandbox

@testset "AppArmor userns sysctl helpers" begin
    props = Sandbox._userns_sysctl_props

    mktempdir() do proc_sys
        @test Sandbox._read_userns_sysctl(props[1]; proc_sys) === nothing
        @test isempty(Sandbox._available_userns_sysctl_props(;
            sysctl_exists = prop -> Sandbox._userns_sysctl_exists(prop; proc_sys),
        ))

        sysctl_path = Sandbox._userns_sysctl_path(props[1]; proc_sys)
        mkpath(dirname(sysctl_path))
        write(sysctl_path, "1\n")

        @test Sandbox._userns_sysctl_exists(props[1]; proc_sys)
        @test Sandbox._read_userns_sysctl(props[1]; proc_sys) == "1"
        @test Sandbox._available_userns_sysctl_props(;
            sysctl_exists = prop -> Sandbox._userns_sysctl_exists(prop; proc_sys),
        ) == [props[1]]
    end

    values = Dict(props[1] => "1", props[2] => nothing)
    @test Sandbox._restricted_userns_sysctl_props(; read_sysctl = prop -> get(values, prop, nothing)) == [props[1]]

    values[props[1]] = "0"
    values[props[2]] = "1"
    @test Sandbox._restricted_userns_sysctl_props(; read_sysctl = prop -> get(values, prop, nothing)) == [props[2]]

    empty!(values)
    @test isempty(Sandbox._restricted_userns_sysctl_props(; read_sysctl = prop -> get(values, prop, nothing)))
end
