set windows-shell := ["powershell"]

tracy := "false"

debug := "-debug"
# debug := ""

alias a1 := build
alias a2 := build-assets

build:
    odin build src -build-mode:shared -define:VALIDATION=true \
    -out:bin/app.dll -show-timings -o:none -use-separate-modules \
    -collection:packages=packages -define:GLFW_SHARED=true {{debug}} \
    -define:TRACY_ENABLE={{tracy}}

build-assets:
    glslc -fshader-stage=frag assets/shaders/Builtin.Object.frag.glsl -o bin/assets/shaders/Builtin.Object.frag.spv --target-env=vulkan
    glslc -fshader-stage=vert assets/shaders/Builtin.Object.vert.glsl -o bin/assets/shaders/Builtin.Object.vert.spv --target-env=vulkan
    spirv-link bin/assets/shaders/Builtin.Object.frag.spv bin/assets/shaders/Builtin.Object.vert.spv -o bin/assets/shaders/Builtin.Object.spv

    glslc -fshader-stage=frag assets/shaders/Builtin.Cubemap.frag.glsl -o bin/assets/shaders/Builtin.Cubemap.frag.spv
    glslc -fshader-stage=vert assets/shaders/Builtin.Cubemap.vert.glsl -o bin/assets/shaders/Builtin.Cubemap.vert.spv 
    spirv-link bin/assets/shaders/Builtin.Cubemap.frag.spv bin/assets/shaders/Builtin.Cubemap.vert.spv -o bin/assets/shaders/Builtin.Cubemap.spv

run:
    odin run loader -use-separate-modules -collection:packages=packages \
    -o:none -define:GLFW_SHARED=true {{debug}} -define:TRACY_ENABLE={{tracy}}

debugger:
    raddbg.exe --profile:vulkan_test.raddbgprofile -auto_run
