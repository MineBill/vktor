package main
import "core:log"
import "core:os"
import vk "vendor:vulkan"

Shader :: struct {
    device:                 ^Device,
    vertex_path:            string,
    vertex_module:          vk.ShaderModule,
    vertex_create_info:     vk.ShaderModuleCreateInfo,
    fragment_path:          string,
    fragment_module:        vk.ShaderModule,
    fragment_create_info:   vk.ShaderModuleCreateInfo,

    // A pointer to the owning pipeline.
    // Used for shader reloading.
    pipeline:               ^Pipeline,
}

load_shader_from_file :: proc(path: string) -> []byte {
    data, ok := os.read_entire_file(path)
    if !ok {
        panic("Failed to read file")
    }

    return data
}

create_shader :: proc(device: ^Device, vertex_path, fragment_path: string) -> (shader: Shader) {
    shader.device = device
    shader.vertex_path = vertex_path
    shader.fragment_path = fragment_path

    vertex_data, ok := os.read_entire_file(vertex_path)
    if !ok {
        log.errorf("Failed to load vertex shader %v", vertex_path)
    }

    fragment_data, ok2 := os.read_entire_file(fragment_path)
    if !ok2 {
        log.errorf("Failed to load fragment shader %v", fragment_path)
    }

    shader.vertex_create_info = vk.ShaderModuleCreateInfo {
        sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
        codeSize = len(vertex_data),
        pCode = raw_data(transmute([]u32)vertex_data),
    }

    vk_check(vk.CreateShaderModule(device.device, &shader.vertex_create_info, nil, &shader.vertex_module))

    shader.fragment_create_info = vk.ShaderModuleCreateInfo {
        sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
        codeSize = len(fragment_data),
        pCode = raw_data(transmute([]u32)fragment_data),
    }

    vk_check(vk.CreateShaderModule(device.device, &shader.fragment_create_info, nil, &shader.fragment_module))

    return
}

destroy_shader :: proc(shader: ^Shader) {
    vk.DestroyShaderModule(shader.device.device, shader.vertex_module, nil)
    vk.DestroyShaderModule(shader.device.device, shader.fragment_module, nil)
}
