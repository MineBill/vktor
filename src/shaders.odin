package main
import "core:log"
import "core:os"
import vk "vendor:vulkan"

load_shader_from_file :: proc(path: string) -> []byte {
    data, ok := os.read_entire_file(path)
    if !ok {
        panic("Failed to read file")
    }

    return data
}

create_shader_module :: proc(bytecode: []byte, device: vk.Device) -> (module: vk.ShaderModule) {
    log.infof("size of shader bytecode: %v", len(bytecode))
    create_info := vk.ShaderModuleCreateInfo {
        sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
        codeSize = len(bytecode),
        pCode = raw_data(transmute([]u32)bytecode),
    }

    result := vk.CreateShaderModule(device, &create_info, nil, &module)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create shader module")
    }
    return
}
