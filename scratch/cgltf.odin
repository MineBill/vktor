package scratch

import "core:os"
import gltf "vendor:cgltf"
import "core:log"

main :: proc() {
    context.logger = log.create_console_logger()

    model_data, ok := os.read_entire_file_from_filename("../assets/models/viking_room.glb")
    if !ok  {
        log.errorf("Failed to read file")
        return
    }

    options := gltf.options {

    }
    data, res := gltf.parse(options, raw_data(model_data), len(model_data))
    if res != .success {
        log.errorf("Error while loading model: %v", res)
    }

    res = gltf.load_buffers(options, data, "../assets/models/viking_room.glb")
    if res != .success {
        log.errorf("Error while loading buffers: %v", res)
    }

    log.debugf("size_of(f32): %v", size_of(f32))

    scene := data.scenes[0]
    log.debugf("Using scene: %v", scene.name)

    node := scene.nodes[0]
    log.debugf("Using first node: %v", node.name)

    mesh := node.mesh
    log.debugf("Using mesh: %v", mesh.name)

    process_mesh(mesh)
}

process_mesh :: proc(mesh: ^gltf.mesh) {
    log.debugf("Mesh has %v primitives", len(mesh.primitives))
    for primitive in mesh.primitives {
        log.debugf("\tPrimitive %v", primitive.type)

        for attr in primitive.attributes
        {
        // attr := primitive.attributes[1]
            log.debugf("\t\tAttribute %v %v", attr.name, attr.type)

            accessor := attr.data
            log.debugf("\t\tComponent type %v", accessor.component_type)
            log.debugf("\t\tCount %v", accessor.count)
            
            data := accessor.buffer_view.buffer.data
            offset := accessor.buffer_view.offset
            log.debugf("\t\tData: %v\tOffset: %v", data, offset)

            positions := cast([^]f32)(uintptr(data) + uintptr(offset))
            count := accessor.count

            #partial switch attr.type {
            case .position:
                count *= 3
            case .texcoord:
                count *= 2
            case .normal:
                count *= 2
            }

            positions2 := positions[:count]
            log.debugf("\t\t\tAttribute Data: %v", positions2[len(positions2) - 1])
            log.debug()
        }

        accessor := primitive.indices
        data := accessor.buffer_view.buffer.data
        offset := accessor.buffer_view.offset
        log.debugf("\t\tData: %v\tOffset: %v", data, offset)

        indices_raw := cast([^]u16)(uintptr(data) + uintptr(offset))
        count := accessor.count
        indices := indices_raw[:count]

        log.debugf("\tIndices: %v Count %v", indices[len(indices) - 1], len(indices))
        log.debugf("\t\tComonent Type: %v", accessor.component_type)
    }
}
