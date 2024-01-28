package main
import "core:fmt"
import "core:log"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"
import "core:mem"
import "core:strings"
import "core:runtime"
import "core:math"
import "core:time"
import "core:math/linalg"
import "core:os"
import gltf "vendor:cgltf"
// import "../packages/tinyobjloader"
import win "../window"

VALIDATION :: #config(VALIDATION, false)

WINDOW_WIDTH  :: 600
WINDOW_HEIGHT :: 400
WINDOW_TITLE  :: "Vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

v2 :: proc(x, y: f32) -> vec2 {
    return vec2{x, y}
}

mat3 :: matrix[3, 3]f32
mat4 :: matrix[4, 4]f32

Uniform_Buffer_Object :: struct {
    model:  mat4,
    view:   mat4,
    proj:   mat4,
}

Camera :: struct {
    position: vec3,
    rotation: mat4,
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
}

@(export)
init :: proc(window: ^win.Window) -> rawptr {
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
    log.debugf("%v", vk.CreateInstance)

    app := new(Application)
    app.window = window
    app.start_time = time.now()

    app.odin_context = context

    app.camera.position = vec3{3, 3, 3}

    app.dbg_context = new(Debug_Context)
    app.dbg_context^ = Debug_Context{
        logger = context.logger,
    }

    app.device              = create_device(window, app.dbg_context)
    app.swapchain           = create_swapchain(&app.device)

    app.descriptor_layout   = create_descriptor_set_layout(&app.device)
    app.descriptor_pool     = device_create_descriptor_pool(&app.device, MAX_FRAMES_IN_FLIGHT)
    app.descriptor_sets     = device_allocate_descriptor_sets(&app.device, app.descriptor_pool, MAX_FRAMES_IN_FLIGHT, app.descriptor_layout)
    app.layout              = create_pipeline_layout(&app.device, app.descriptor_layout)
    app.simple_pipeline     = create_pipeline(&app.swapchain, &app.device, app.layout, app.descriptor_layout)
    app.command_buffers     = create_command_buffers(&app.device, MAX_FRAMES_IN_FLIGHT)

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

    // main_loop: for !window_should_close(app.window) {
    //     window_update(app.window)

    //     event_loop: for event in app.events {
    //         #partial switch a in event {
    //         case KeyEvent:
    //             if a.key == .escape {
    //                 break main_loop
    //             }
    //             if a.key == .g {
    //                 log.debugf("Key event: %v", a)
    //                 image_set_lod_bias(app.image_view.image, 5)
    //             }
    //         case WindowResizedEvent:
    //             log.debugf("Window resized: %v", a)
    //             if a.size.x == 0 || a.size.y == 0 {
    //                 app.minimized = true
    //                 break event_loop
    //             }
    //             app.minimized = false
    //             app.resized = true

    //         }
    //     }

    //     draw_frame(&app)

    //     flush_input()
    //     clear(&app.events)
    // }

    // vk.DeviceWaitIdle(app.device.device)
    return app
}

@(export)
update :: proc(mem: rawptr) -> bool {
    app := cast(^Application)mem
    @static mouse: vec2
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

    @static time_count := f32(0.0)
    current_time := time.now()
    t := f32(time.duration_seconds(time.diff(app.start_time, current_time)))
    time_count += t

    app.camera.position.y = math.sin(t)
    app.camera.rotation = linalg.matrix4_look_at(app.camera.position, vec3{0, 0, 0}, vec3{0, -1, 0}, false)

    draw_frame(app)

    return false
}

@(export)
reloaded :: proc(mem: rawptr) {
    app := cast(^Application)mem
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
    vk.load_proc_addresses_instance(app.device.instance)
}

@(export)
destroy :: proc(mem: rawptr) {
    app := cast(^Application)mem

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

    ubo := Uniform_Buffer_Object {}

    ubo.model = linalg.MATRIX4F32_IDENTITY
    rot := app.camera.rotation
    trans := linalg.matrix4_translate(app.camera.position)
    ubo.view  =  rot * trans
    // ubo.view  = linalg.matrix4_look_at(-pos, vec3{0, 0, 0}, vec3{0, -1, 0}, false)
    ubo.proj  = linalg.matrix4_perspective(
        linalg.to_radians(f32(65.0)), 
        f32(app.swapchain.extent.width) / f32(app.swapchain.extent.height),
        0.1, 100.0, false)
    mem.copy(app.uniform_mapped_buffers[current_image], &ubo, size_of(ubo))
}

create_uniform_buffers :: proc(app: ^Application) {
    app.uniform_buffers = make([]Buffer, MAX_FRAMES_IN_FLIGHT)
    app.uniform_mapped_buffers = make([]rawptr, MAX_FRAMES_IN_FLIGHT)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        size := u32(size_of(Uniform_Buffer_Object))
        app.uniform_buffers[i] = buffer_create(
            &app.device, 
            size, 
            {.UNIFORM_BUFFER},
            {.HOST_VISIBLE, .HOST_COHERENT})

        vk.MapMemory(
            app.device.device,
            app.uniform_buffers[i].memory,
            0, vk.DeviceSize(size),
            {},
            &app.uniform_mapped_buffers[i])

        buffer_info := vk.DescriptorBufferInfo {
            buffer = app.uniform_buffers[i].handle,
            offset = 0,
            range = size_of(Uniform_Buffer_Object),
        }

        image_info := vk.DescriptorImageInfo {
            imageLayout = .READ_ONLY_OPTIMAL,
            imageView = app.image_view.handle,
            sampler = app.image_view.image.sampler,
        }

        descriptor_writes := []vk.WriteDescriptorSet{
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
        }
        vk.UpdateDescriptorSets(app.device.device, u32(len(descriptor_writes)), raw_data(descriptor_writes), 0, nil)
    }
}

update_descriptor_sets :: proc() {

}

create_pipeline_layout :: proc(device: ^Device, descriptor_set_layout: vk.DescriptorSetLayout) -> (layout: vk.PipelineLayout) {
    descriptor_set_layout := descriptor_set_layout
    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 0,
        setLayoutCount = 1,
        pSetLayouts = &descriptor_set_layout,
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
        stageFlags = {.VERTEX},
    }

    sampler_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 1,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        stageFlags = {.FRAGMENT},
        pImmutableSamplers = nil,
    }

    bindings := []vk.DescriptorSetLayoutBinding{ubo_layout_binding, sampler_layout_binding}

    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(bindings)),
        pBindings = raw_data(bindings),
    }

    vk_check(vk.CreateDescriptorSetLayout(device.device, &layout_info, nil, &layout))
    return
}

create_pipeline :: proc(
    swapchain: ^Swapchain,
    device: ^Device,
    layout: vk.PipelineLayout,
    descriptor_layout: vk.DescriptorSetLayout,
) -> (pipeline: Pipeline) {
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

    swapchain_submit_command_buffers(&app.swapchain, {app.command_buffers[app.swapchain.current_frame]})
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
        renderArea = vk.Rect2D {
            offset = {0, 0},
            extent = a.swapchain.extent,
        },
        clearValueCount = u32(len(clear_values)),
        pClearValues = raw_data(clear_values),
    }

    vk.CmdBeginRenderPass(command_buffer, &render_pass_info, vk.SubpassContents.INLINE)

        vk.CmdBindPipeline(command_buffer, vk.PipelineBindPoint.GRAPHICS, a.simple_pipeline.pipeline)

        viewport := vk.Viewport {
            x = 0,
            y = 0,
            width = cast(f32)a.swapchain.extent.width,
            height = cast(f32)a.swapchain.extent.height,
            minDepth = 0,
            maxDepth = 1,
        }
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

        scissor := vk.Rect2D {
            offset = {0, 0},
            extent = a.swapchain.extent,
        }
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

        for model in a.scene.models {
            buffers: []vk.Buffer = {model.vertex_buffer.handle}
            offsets: []vk.DeviceSize = {0}
            vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(buffers), raw_data(offsets))

            vk.CmdBindIndexBuffer(command_buffer, model.index_buffer.handle, 0, .UINT16)

            vk.CmdBindDescriptorSets(
                command_buffer,
                .GRAPHICS,
                a.layout,
                0,
                1,
                &a.descriptor_sets[a.swapchain.current_frame],
                0,
                nil)

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
        model := Model{
            material = default_material(),
        }
        
        for primitive in mesh.primitives {

            get_buffer_data :: proc(attributes: []gltf.attribute, index: u32, $T: typeid) -> []T {
                accessor := attributes[index].data
                data := cast([^]T)(uintptr(accessor.buffer_view.buffer.data) + uintptr(accessor.buffer_view.offset))
                count := accessor.count
                #partial switch attributes[index].type {
                case .position:
                    count *= 3
                case .texcoord:
                    count *= 2
                case .normal:
                    count *= 2
                }
                return data[:count]
            }

            position_data := get_buffer_data(primitive.attributes, 0, f32)

            normal_data := get_buffer_data(primitive.attributes, 1, f32)

            tex_data := get_buffer_data(primitive.attributes, 2, f32)

            vertices := make([]Vertex, len(position_data) / 3)

            vi := 0
            ti := 0
            for i := 0; i < len(vertices) - 0; i += 1 {
                vertices[i] = Vertex {
                    pos = {position_data[vi], position_data[vi + 1], position_data[vi + 2]},
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
        }
    
        append(&scene.models, model)
    }

    return
}

Material :: struct {
    albedo_color:  vec4,
}

default_material :: proc() -> Material {
    return {
        albedo_color = vec4{1, 1, 1, 1},
    }
}

Model :: struct {
    vertex_buffer:  Buffer,
    index_buffer:   Buffer,
    num_indices:    u32,
    material:       Material,
    // device_address
}

model_create :: proc() {}

Vertex :: struct {
    pos:        vec3,
    color:      vec3,
    texCoord:   vec2,
}

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
    return {
        binding = 0,
        stride = size_of(Vertex),
        inputRate = vk.VertexInputRate.VERTEX,
    }
}

vertex_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
    return {
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
            offset = u32(offset_of(Vertex, color)),
        },
        {
            binding = 0,
            location = 2,
            format = vk.Format.R32G32_SFLOAT,
            offset = u32(offset_of(Vertex, texCoord)),
        },
    }
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
