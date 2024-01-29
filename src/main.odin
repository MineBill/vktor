package main
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:runtime"
import "core:strings"
import "core:time"
import gltf "vendor:cgltf"
import "vendor:glfw"
import vk "vendor:vulkan"
import win "../window"
import "core:sys/windows"
import "core:thread"

VALIDATION :: #config(VALIDATION, false)

WINDOW_WIDTH :: 600
WINDOW_HEIGHT :: 400
WINDOW_TITLE :: "Vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

v2 :: proc(x, y: f32) -> vec2 {
    return vec2{x, y}
}

mat3 :: matrix[3, 3]f32
mat4 :: matrix[4, 4]f32

View_Data :: struct {
    model: mat4,
    view:  mat4,
    proj:  mat4,
}

Uniform_Buffer_Object :: struct {
    view_data: View_Data,
    scene_data: Scene_Data,
}

Main_Light :: struct {
    position: vec4,
    color: vec4,
}

Scene_Data :: struct {
    view_position: vec4,
    main_light: Main_Light,
}

Camera :: struct {
    position: vec3,
    rotation: mat4,
}

Thread_Data :: struct {
    paths:         []string,
    handle:        windows.HANDLE,
    should_reload: bool,
}

Application :: struct {
    window:                 ^win.Window,
    start_time:             time.Time,
    device:                 Device,
    swapchain:              Swapchain,
    simple_pipeline:        Pipeline,
    layout:                 vk.PipelineLayout,
    command_buffers:        []vk.CommandBuffer,
    descriptor_sets:        []vk.DescriptorSet,
    descriptor_layout:      vk.DescriptorSetLayout,
    descriptor_pool:        vk.DescriptorPool,
    uniform_buffers:        []Buffer,
    uniform_mapped_buffers: []rawptr,
    camera:                 Camera,
    image:                  Image,
    image_view:             Image_View,
    minimized:              bool,
    resized:                bool,
    scene:                  Scene,
    odin_context:           runtime.Context,
    dbg_context:            ^Debug_Context,
    thread_data:            ^Thread_Data,
    thread:                 ^thread.Thread,

    scene_data:             Scene_Data,
}

@(export)
init :: proc(window: ^win.Window) -> rawptr {
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
    if vk.CreateInstance == nil {
        a := typeid_of(type_of(vk.CreateInstance))
        log.errorf("Vulkan proc is nil after loading proc addresses. Something is up.", a)
    }

    app := new(Application)
    app.window = window
    app.start_time = time.now()

    app.odin_context = context

    app.camera.position = vec3{3, 3, 3}

    app.dbg_context = new(Debug_Context)
    app.dbg_context^ = Debug_Context {
        logger = context.logger,
    }

    app.device = create_device(window, app.dbg_context)
    app.swapchain = create_swapchain(&app.device)

    app.descriptor_layout = create_descriptor_set_layout(&app.device)
    app.descriptor_pool = device_create_descriptor_pool(&app.device, MAX_FRAMES_IN_FLIGHT)
    app.descriptor_sets = device_allocate_descriptor_sets(
        &app.device,
        app.descriptor_pool,
        MAX_FRAMES_IN_FLIGHT,
        app.descriptor_layout,
    )
    app.layout = create_pipeline_layout(&app.device, app.descriptor_layout)
    app.simple_pipeline = create_pipeline(
        &app.swapchain,
        &app.device,
        app.layout,
        app.descriptor_layout,
    )
    app.command_buffers = create_command_buffers(&app.device, MAX_FRAMES_IN_FLIGHT)

    // app.vertices = []Vertex {
    //     {{-0.5, -0.5,  0.0}, {1.0, 0.0, 1.0}, {1.0, 0.0}},
    //     {{ 0.5, -0.5,  0.0}, {0.0, 1.0, 1.0}, {0.0, 0.0}},
    //     {{ 0.5,  0.5,  0.0}, {0.0, 1.0, 1.0}, {0.0, 1.0}},
    //     {{-0.5,  0.5,  0.0}, {1.0, 1.0, 1.0}, {1.0, 1.0}},

    //     {{-0.5, -0.5, +0.5}, {1.0, 0.0, 1.0}, {1.0, 0.0}},
    //     {{ 0.5, -0.5, +0.5}, {0.0, 1.0, 1.0}, {0.0, 0.0}},
    //     {{ 0.5,  0.5, +0.5}, {0.0, 1.0, 1.0}, {0.0, 1.0}},
    //     {{-0.5,  0.5, +0.5}, {1.0, 1.0, 1.0}, {1.0, 1.0}},
    // }

    // app.indices = []u32 {
    //     0, 1, 2, 2, 3, 0,
    //     4, 5, 6, 6, 7, 4,
    // }

    app.scene = scene_load_from_file(app, "assets/models/cube.glb")

    app.image = image_load_from_file(&app.device, "assets/textures/viking_room.png")
    app.image_view = image_view_create(&app.image, .R8G8B8A8_SRGB, {.COLOR})

    create_uniform_buffers(app)

    app.scene_data.main_light.color = vec4{1, 1, 1, 1}

    // Create background threads to monitor shader source changes
    background_thread :: proc(data: rawptr) {
        data := cast(^Thread_Data)data
        log.infof("Data: ", data)
        handle := data.handle
        for {
            log.info("Waiting for signal")
            wait_status := windows.WaitForSingleObject(handle, windows.INFINITE)
            switch wait_status {
            case windows.WAIT_OBJECT_0:
                buffer: [1024]byte
                bytes_returned: u32
                windows.ReadDirectoryChangesW(
                    handle,
                    &buffer,
                    u32(len(buffer)),
                    false,
                    windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
                    &bytes_returned,
                    nil,
                    nil,
                )

                file_info := cast(^windows.FILE_NOTIFY_INFORMATION)&buffer

                name, _ := windows.wstring_to_utf8(
                    &file_info.file_name[0],
                    cast(int)file_info.file_name_length,
                )
                log.infof("name: %v\n", name)
                for path in data.paths {
                    if strings.contains(path, name) {
                        data.should_reload = true
                    }
                }

                windows.FindNextChangeNotification(handle)
            case windows.WAIT_TIMEOUT:
                // Does this need to be handled?
                unreachable()
            }
        }
    }

    handle := windows.FindFirstChangeNotificationW(
        windows.utf8_to_wstring("bin\\assets\\shaders"),
        true,
        windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
    )
    app.thread_data = new(Thread_Data)
    app.thread_data.handle = handle

    app.thread_data.paths = make([]string, 2)
    copy(
        app.thread_data.paths,
        []string{app.simple_pipeline.shader.vertex_path, app.simple_pipeline.shader.fragment_path},
    )
    thread.run_with_data(app.thread_data, background_thread)

    return app
}

@(export)
update :: proc(mem: rawptr) -> bool {
    app := cast(^Application)mem
    @(static)
    mouse: vec2
    event_loop: for event in app.window.event_context.events {
        #partial switch a in event {
        case win.KeyEvent:
            if a.key == .escape {
                return true
            }
            if a.key == .g {
                log.debugf("Key event: %v", a)
                image_set_lod_bias(app.image_view.image, 5)
            }
            if a.key == .e {
                app.camera.position = vec3{2, 2, 2}
            }
            if a.key == .q {
                app.camera.position = vec3{}
                app.camera.rotation = mat4(1)
            }
            if (a.key == .r && a.state == .pressed) {
                // Reload shaders
                log.info("Reload shaders!")
            }
        case win.WindowResizedEvent:
            log.debugf("Window resized: %v", a)
            if a.size.x == 0 || a.size.y == 0 {
                app.minimized = true
                break event_loop
            }
            app.minimized = false
            app.resized = true
        }
    }

    if app.thread_data.should_reload {
        log.info("Reloading shaders")
        app.simple_pipeline = create_pipeline(
            &app.swapchain,
            &app.device,
            app.layout,
            app.descriptor_layout,
        )
        app.thread_data.should_reload = false
    }

    @(static)
    time_count := f32(0.0)
    current_time := time.now()
    t := f32(time.duration_seconds(time.diff(app.start_time, current_time)))

    app.camera.position.y = math.sin(t * 1) * 1
    app.camera.rotation = linalg.matrix4_look_at(
        app.camera.position,
        vec3{0, 0, 0},
        vec3{0, -1, 0},
        false,
    )
    light := &app.scene_data.main_light
    light.position = vec4{-3, 3, -3, 0}
    light.position.y = -math.sin(t * 1) * 1
    light.color = vec4{1, 1, 1, 0}

    draw_frame(app)

    return false
}

@(export)
reloaded :: proc(mem: rawptr) {
    app := cast(^Application)mem
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
    vk.load_proc_addresses_instance(app.device.instance)

    // Restart background shader monitoring thread
}

@(export)
destroy :: proc(mem: rawptr) {
    app := cast(^Application)mem
    windows.FindCloseChangeNotification(app.thread_data.handle)

    for &buffer in app.uniform_buffers {
        buffer_destroy(&buffer)
    }
    delete(app.uniform_buffers)
    delete(app.uniform_mapped_buffers)

    image_view_destroy(&app.image_view)
    image_destroy(&app.image)

    vk.DeviceWaitIdle(app.device.device)
    free_command_buffers(&app.device, app.command_buffers)
    destroy_grphics_pipeline(&app.simple_pipeline)
    vk.DestroyPipelineLayout(app.device.device, app.layout, nil)
    delete(app.descriptor_sets)
    device_destroy_descriptor_pool(&app.device, app.descriptor_pool)
    vk.DestroyDescriptorSetLayout(app.device.device, app.descriptor_layout, nil)
    destroy_swapchain(&app.swapchain)
    destroy_device(&app.device)

    free(app.dbg_context)
    free(app)
}

update_uniform_buffer :: proc(app: ^Application, current_image: u32) {
    ubo := Uniform_Buffer_Object{}

    ubo.scene_data = app.scene_data
    ubo.view_data.model = linalg.MATRIX4F32_IDENTITY
    rot := app.camera.rotation
    trans := linalg.matrix4_translate(app.camera.position)
    ubo.view_data.view = rot * trans
    // ubo.view  = linalg.matrix4_look_at(-pos, vec3{0, 0, 0}, vec3{0, -1, 0}, false)
    ubo.view_data.proj = linalg.matrix4_perspective(
        linalg.to_radians(f32(45.0)),
        f32(app.swapchain.extent.width) / f32(app.swapchain.extent.height),
        0.1,
        100.0,
        false,
    )
    mem.copy(app.uniform_mapped_buffers[current_image], &ubo, size_of(ubo))
}

create_uniform_buffers :: proc(app: ^Application) {
    app.uniform_buffers = make([]Buffer, MAX_FRAMES_IN_FLIGHT)
    app.uniform_mapped_buffers = make([]rawptr, MAX_FRAMES_IN_FLIGHT)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        size := u32(size_of(Uniform_Buffer_Object) + size_of(Material))
        app.uniform_buffers[i] = buffer_create(
            &app.device,
            size,
            {.UNIFORM_BUFFER},
            {.HOST_VISIBLE, .HOST_COHERENT},
        )

        vk.MapMemory(
            app.device.device,
            app.uniform_buffers[i].memory,
            0,
            vk.DeviceSize(size),
            {},
            &app.uniform_mapped_buffers[i],
        )

        buffer_info := vk.DescriptorBufferInfo {
            buffer = app.uniform_buffers[i].handle,
            offset = 0,
            range  = size_of(Uniform_Buffer_Object),
        }

        material_info := vk.DescriptorBufferInfo {
            buffer = app.uniform_buffers[i].handle,
            offset = buffer_info.range,
            range  = size_of(Material),
        }

        image_info := vk.DescriptorImageInfo {
            imageLayout = .READ_ONLY_OPTIMAL,
            imageView   = app.image_view.handle,
            sampler     = app.image_view.image.sampler,
        }

        descriptor_writes := []vk.WriteDescriptorSet {
             {
                sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                dstSet = app.descriptor_sets[i],
                dstBinding = 0,
                dstArrayElement = 0,
                descriptorType = .UNIFORM_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &buffer_info,
            },
             {
                sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                dstSet = app.descriptor_sets[i],
                dstBinding = 1,
                dstArrayElement = 0,
                descriptorType = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = 1,
                pImageInfo = &image_info,
            },
             {
                sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                dstSet = app.descriptor_sets[i],
                dstBinding = 2,
                dstArrayElement = 0,
                descriptorType = .UNIFORM_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &material_info,
            },
        }

        vk.UpdateDescriptorSets(
            app.device.device,
            u32(len(descriptor_writes)),
            raw_data(descriptor_writes),
            0,
            nil,
        )
    }
}

update_descriptor_sets :: proc() {

}

create_pipeline_layout :: proc(
    device: ^Device,
    descriptor_set_layout: vk.DescriptorSetLayout,
) -> (
    layout: vk.PipelineLayout,
) {
    descriptor_set_layout := descriptor_set_layout
    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType                  = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 0,
        setLayoutCount         = 1,
        pSetLayouts            = &descriptor_set_layout,
    }

    result := vk.CreatePipelineLayout(device.device, &pipeline_layout_create_info, nil, &layout)

    if result != vk.Result.SUCCESS {
        log.error("Failed to create pipeline layout")
    }
    return
}

create_descriptor_set_layout :: proc(device: ^Device) -> (layout: vk.DescriptorSetLayout) {
    ubo_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorCount = 1,
        descriptorType = vk.DescriptorType.UNIFORM_BUFFER,
        stageFlags = {.VERTEX, .FRAGMENT},
    }

    material_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 2,
        descriptorCount = 1,
        descriptorType = vk.DescriptorType.UNIFORM_BUFFER,
        stageFlags = {.FRAGMENT},
    }

    sampler_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 1,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        stageFlags = {.FRAGMENT},
        pImmutableSamplers = nil,
    }

    bindings := []vk.DescriptorSetLayoutBinding {
        ubo_layout_binding,
        sampler_layout_binding,
        material_layout_binding,
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType        = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(bindings)),
        pBindings    = raw_data(bindings),
    }

    vk_check(vk.CreateDescriptorSetLayout(device.device, &layout_info, nil, &layout))
    return
}

create_pipeline :: proc(
    swapchain: ^Swapchain,
    device: ^Device,
    layout: vk.PipelineLayout,
    descriptor_layout: vk.DescriptorSetLayout,
) -> (
    pipeline: Pipeline,
) {
    config := default_pipeline_config()
    config.renderpass = swapchain.renderpass
    config.layout = layout
    config.descriptor_set_layout = descriptor_layout
    pipeline = create_graphics_pipeline(device, config)
    return
}

vk_check :: proc(result: vk.Result, location := #caller_location) {
    if result == vk.Result.SUCCESS do return
    log.errorf("Vulkan call failed: ", result, location)
}

draw_frame :: proc(app: ^Application) {
    if app.minimized do return

    image_index, err := swapchain_acquire_next_image(&app.swapchain)
    if err == .ERROR_OUT_OF_DATE_KHR || err == .SUBOPTIMAL_KHR || app.resized {
        app.resized = false
        vk.DeviceWaitIdle(app.swapchain.device.device)
        destroy_swapchain(&app.swapchain)
        app.swapchain = create_swapchain(app.swapchain.device)
        return
    }

    if err != .SUCCESS {
        return
    }

    vk.ResetCommandBuffer(app.command_buffers[app.swapchain.current_frame], {})
    record_command_buffer(app, image_index)

    update_uniform_buffer(app, u32(app.swapchain.current_frame))

    swapchain_submit_command_buffers(
        &app.swapchain,
        {app.command_buffers[app.swapchain.current_frame]},
    )
    swapchain_present(&app.swapchain, image_index)
}

Debug_Context :: struct {
    logger: log.Logger,
}

record_command_buffer :: proc(a: ^Application, image_index: u32) {
    command_buffer := a.command_buffers[a.swapchain.current_frame]
    begin_info := vk.CommandBufferBeginInfo {
        sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
    }

    result := vk.BeginCommandBuffer(command_buffer, &begin_info)
    if result != vk.Result.SUCCESS {
        log.error("Failed to begin command buffer")
    }

    clear_values := []vk.ClearValue {
        {color = {float32 = {0.01, 0.01, 0.01, 1.0}}},
        {depthStencil = {1, 0}},
    }

    render_pass_info := vk.RenderPassBeginInfo {
        sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
        renderPass = a.swapchain.renderpass,
        framebuffer = a.swapchain.framebuffers[image_index],
        renderArea = vk.Rect2D{offset = {0, 0}, extent = a.swapchain.extent},
        clearValueCount = u32(len(clear_values)),
        pClearValues = raw_data(clear_values),
    }

    vk.CmdBeginRenderPass(command_buffer, &render_pass_info, vk.SubpassContents.INLINE)

    vk.CmdBindPipeline(command_buffer, vk.PipelineBindPoint.GRAPHICS, a.simple_pipeline.pipeline)

    viewport := vk.Viewport {
        x        = 0,
        y        = 0,
        width    = cast(f32)a.swapchain.extent.width,
        height   = cast(f32)a.swapchain.extent.height,
        minDepth = 0,
        maxDepth = 1,
    }
    vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

    scissor := vk.Rect2D {
        offset = {0, 0},
        extent = a.swapchain.extent,
    }
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

    for &model in a.scene.models {
        buffers: []vk.Buffer = {model.vertex_buffer.handle}
        offsets: []vk.DeviceSize = {0}
        vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(buffers), raw_data(offsets))

        vk.CmdBindIndexBuffer(command_buffer, model.index_buffer.handle, 0, .UINT16)

        mem.copy(
            rawptr(
                uintptr(a.uniform_mapped_buffers[a.swapchain.current_frame]) +
                uintptr(size_of(Uniform_Buffer_Object)),
            ),
            &model.material,
            size_of(Material),
        )
        vk.CmdBindDescriptorSets(
            command_buffer,
            .GRAPHICS,
            a.layout,
            0,
            1,
            &a.descriptor_sets[a.swapchain.current_frame],
            0,
            nil,
        )

        vk.CmdDrawIndexed(command_buffer, model.num_indices, 1, 0, 0, 0)
    }

    vk.CmdEndRenderPass(command_buffer)

    vk_check(vk.EndCommandBuffer(command_buffer))
}

Scene :: struct {
    models: [dynamic]Model,
}

scene_load_from_file :: proc(app: ^Application, file: string) -> (scene: Scene) {
    model_data, ok := os.read_entire_file_from_filename(file)
    if !ok do return {}

    options := gltf.options{}
    data, res := gltf.parse(options, raw_data(model_data), len(model_data))
    if res != .success {
        log.errorf("Error while loading model: %v", res)
    }

    res = gltf.load_buffers(options, data, strings.clone_to_cstring(file, context.temp_allocator))
    if res != .success {
        log.errorf("Error while loading model: %v", res)
    }

    assert(len(data.scenes) == 1)
    s := data.scenes[0]

    for node in s.nodes {
        log.debugf("Processing node %v", node.name)
        // if node.name != "Cube.002" do continue
        mesh := node.mesh
        model := Model {
            material = default_material(),
        }

        for primitive in mesh.primitives {

            get_buffer_data :: proc(attributes: []gltf.attribute, index: u32, $T: typeid) -> []T {
                accessor := attributes[index].data
                data := cast([^]T)(uintptr(accessor.buffer_view.buffer.data) +
                    uintptr(accessor.buffer_view.offset))
                count := accessor.count
                #partial switch attributes[index].type {
                case .normal:
                    fallthrough
                case .position:
                    count *= 3
                case .texcoord:
                    count *= 2
                }
                return data[:count]
            }

            position_data := get_buffer_data(primitive.attributes, 0, f32)

            normal_data := get_buffer_data(primitive.attributes, 1, f32)

            tex_data := get_buffer_data(primitive.attributes, 2, f32)

            vertices := make([]Vertex, len(position_data) / 3)

            log.debugf("Normal count: %v", len(normal_data))
            log.debugf("Posiiton count: %v", len(position_data))

            vi := 0
            ti := 0
            for i := 0; i < len(vertices) - 0; i += 1 {
                vertices[i] = Vertex {
                    pos = {position_data[vi], position_data[vi + 1], position_data[vi + 2]},
                    normal = {normal_data[vi], normal_data[vi + 1], normal_data[vi + 2]},
                    color = {1, 1, 1},
                    texCoord = {tex_data[ti], tex_data[ti + 1]},
                }
                vertices[i].pos += node.translation
                vi += 3
                ti += 2
            }

            accessor := primitive.indices
            data := accessor.buffer_view.buffer.data
            offset := accessor.buffer_view.offset

            indices_raw := cast([^]u16)(uintptr(data) + uintptr(offset))
            count := accessor.count
            indices := indices_raw[:count]

            model.vertex_buffer = create_vertex_buffer(&app.device, vertices)
            model.index_buffer = create_index_buffer(&app.device, indices)
            model.num_indices = u32(len(indices))

            material:^gltf.material = primitive.material
            if material != nil {
                log.debugf("Processing material %v", material.name)
            }
        }

        append(&scene.models, model)
    }

    return
}

Material :: struct {
    albedo_color:   vec4,
    roughness:      f32,
}

default_material :: proc() -> Material {
    return {albedo_color = vec4{1, 1, 1, 1}, roughness = 1}
}

Model :: struct {
    vertex_buffer:  Buffer,
    index_buffer:   Buffer,

    image:          Image,
    image_view:     Image_View,

    num_indices:    u32,
    material:       Material,
    buffer:         Buffer,
    buffer_map:     rawptr,
    descriptor_set: vk.DescriptorSet,
}

model_create :: proc() {

}

// model_init :: proc(model: ^Model, device: ^Device) {
//     size := u32(size_of(Material))
//     model.buffer = buffer_create(
//         device,
//         size,
//         {.UNIFORM_BUFFER},
//         {.HOST_VISIBLE, .HOST_COHERENT},
//     )

//     vk.MapMemory(
//         device.device,
//         model.buffer.memory,
//         0,
//         vk.DeviceSize(size),
//         {},
//         &model.buffer_map,
//     )

//     buffer_info := vk.DescriptorBufferInfo {
//         buffer = model.buffer.handle,
//         offset = 0,
//         range = size_of(Material),
//     }

//     writes := []vk.WriteDescriptorSet {
//         {
//             sType = .WRITE_DESCRIPTOR_SET,
//             dstSet = model.descriptor_set,
//             dstBinding = 0,
//         }
//     }

//     vk.UpdateDescriptorSets(
//         device.device,
//         1,
//         &buffer_info,
//         0,
//         nil,
//     )
// }

Vertex :: struct {
    pos:      vec3,
    normal:   vec3,
    color:    vec3,
    texCoord: vec2,
}

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
    return {binding = 0, stride = size_of(Vertex), inputRate = vk.VertexInputRate.VERTEX}
}

vertex_attribute_descriptions :: proc() -> [4]vk.VertexInputAttributeDescription {
    return(
         {
             {
                binding = 0,
                location = 0,
                format = vk.Format.R32G32B32_SFLOAT,
                offset = u32(offset_of(Vertex, pos)),
            },
             {
                binding = 0,
                location = 1,
                format = vk.Format.R32G32B32_SFLOAT,
                offset = u32(offset_of(Vertex, normal)),
            },
             {
                binding = 0,
                location = 2,
                format = vk.Format.R32G32B32_SFLOAT,
                offset = u32(offset_of(Vertex, color)),
            },
             {
                binding = 0,
                location = 3,
                format = vk.Format.R32G32_SFLOAT,
                offset = u32(offset_of(Vertex, texCoord)),
            },
        } \
    )
}

// main :: proc() {
//     context.logger = log.create_console_logger()
//     win.initialize_windowing()
//     window := win.create(640, 480, "Vulkan Window")
//     win.setup_events(&window)

//     mem := init(&window)

//     main_loop: for !win.should_close(window) {
//         win.update(&window)

//         quit := update(mem)
//         if quit do break main_loop
//     }
// }
