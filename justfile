set windows-shell := ["powershell"]

collections := "awd"

# debug := "-debug"
debug := ""

alias a1 := build
alias a2 := build-assets

build:
    odin build src -build-mode:dll -define:VALIDATION=true \
    -out:bin/app.dll -show-timings -o:none -use-separate-modules \
    -collection:packages=packages -define:GLFW_SHARED=true {{debug}}

build-assets:
    # mkdir -p bin/assets/shaders
    echo assets/shaders/Builtin.Object.frag.glsl -> bin/assets/shaders/Builtin.Object.frag.spv
    glslc -fshader-stage=frag assets/shaders/Builtin.Object.frag.glsl -o bin/assets/shaders/Builtin.Object.frag.spv

    echo assets/shaders/Builtin.Object.vert.glsl -> bin/assets/shaders/Builtin.Object.vert.spv
    glslc -fshader-stage=vert assets/shaders/Builtin.Object.vert.glsl -o bin/assets/shaders/Builtin.Object.vert.spv 

run:
    odin run loader -use-separate-modules -collection:packages=packages \
    -o:none -define:GLFW_SHARED=true {{debug}}

debugger:
    raddbg.exe --profile:vulkan_test.raddbgprofile -auto_run
