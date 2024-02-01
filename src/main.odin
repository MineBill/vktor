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
// import "core:sys/windows"
import "core:thread"
import "core:image/png"
import stbi "vendor:stb/image"
import "../monitor"
// import tracy "packages:odin-tracy"

VALIDATION :: #config(VALIDATION, false)

WINDOW_WIDTH :: 600
WINDOW_HEIGHT :: 400
WINDOW_TITLE :: "Vulkan"

MAX_FRAMES_IN_FLIGHT :: 1

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

v2 :: proc(x, y: f32) -> vec2 {
    return vec2{x, y}
}

mat3 :: matrix[3, 3]f32
mat4 :: matrix[4, 4]f32

View_Data :: struct {
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
    position:       vec3,
    rotation:       quaternion128,
    euler_angles:   vec3,
    fov:            f32,
}

Application :: struct {
    window:                     glfw.WindowHandle,
    start_time:                 time.Time,
    device:                     Device,
    swapchain:                  Swapchain,
    simple_pipeline:            Pipeline,
    layout:                     vk.PipelineLayout,
    command_buffers:            []vk.CommandBuffer,
    descriptor_sets:            []vk.DescriptorSet,
    global_descriptor_layout:   vk.DescriptorSetLayout,
    material_layout:            vk.DescriptorSetLayout,
    descriptor_pool:            vk.DescriptorPool,
    uniform_buffers:            []Buffer,
    uniform_mapped_buffers:     []rawptr,
    camera:                     Camera,
    image:                      Image,
    minimized:                  bool,
    resized:                    bool,
    scene:                      Scene,
    odin_context:               runtime.Context,
    dbg_context:                ^Debug_Context,
    shader_monitor:             monitor.Monitor,
    thread:                     ^thread.Thread,

    cubemap_pipeline:       Cubemap_Pipeline,

    scene_data:             Scene_Data,
    event_context:          Event_Context,
    mouse_locked:           bool,
}

@(export)
init :: proc(window: glfw.WindowHandle) -> rawptr {
    // tracy.ZoneN("Application Init")
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
    if vk.CreateInstance == nil {
        a := typeid_of(type_of(vk.CreateInstance))
        log.errorf("Vulkan proc is nil after loading proc addresses. Something is up: %v", a)
    }

    app := new(Application)
    app.window = window
    app.start_time = time.now()

    app.odin_context = context

    app.camera.position = vec3{1, 1, 1}
    NOT_PI :: 3.14
    app.camera.euler_angles = vec3{0, NOT_PI/2, 0}
    app.camera.fov = 50

    app.dbg_context = new(Debug_Context)
    app.dbg_context^ = Debug_Context {
        logger = context.logger,
    }
    app.event_context.odin_context = context

    setup_events(window, &app.event_context)

    app.device = create_device(window, app.dbg_context)
    // app.swapchain = create_swapchain(&app.device)
    init_swapchain(&app.device, &app.swapchain)

    app.material_layout = create_material_set_layout(&app.device)
    app.global_descriptor_layout = create_global_descriptor_set_layout(&app.device)
    app.descriptor_pool = device_create_descriptor_pool(&app.device, MAX_FRAMES_IN_FLIGHT, {
        {type = vk.DescriptorType.UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
        {type = vk.DescriptorType.COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
        },
    )
    app.descriptor_sets = device_allocate_descriptor_sets(
        &app.device,
        app.descriptor_pool,
        MAX_FRAMES_IN_FLIGHT,
        app.global_descriptor_layout,
    )
    app.layout = create_pipeline_layout(app)
    app.simple_pipeline = create_pipeline(
        &app.swapchain,
        &app.device,
        app.layout,
        app.global_descriptor_layout,
    )

    cubemap_init(&app.cubemap_pipeline, &app.device, &app.swapchain)

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

    app.scene = scene_load_from_file(app, "assets/models/scene.glb")

    app.image = image_load_from_file(&app.device, "assets/textures/viking_room.png")
    image_view_create(&app.image, .R8G8B8A8_SRGB, {.COLOR})

    create_uniform_buffers(app)

    app.scene_data.main_light.color = vec4{1, 1, 1, 1}

    monitor.init(&app.shader_monitor, "bin/assets/shaders", {
        "Builtin.Object.spv",
        "Builtin.Cubemap.spv",
    })
    thread.run_with_data(&app.shader_monitor, monitor.thread_proc)

    return app
}

@(export)
update :: proc(mem: rawptr, delta: f64) -> bool {
    // tracy.ZoneN("Application Update")
    app := cast(^Application)mem
    @(static)
    mouse: vec2
    event_loop: for event in app.event_context.events {
        #partial switch a in event {
        case KeyEvent:
            if a.key == .escape {
                return true
            }

            if a.key == .f && a.state == .pressed {
                app.mouse_locked = !app.mouse_locked
                log.infof("Mouse is now %v", "locked" if app.mouse_locked else "unlocked")
                if app.mouse_locked {
                    glfw.SetInputMode(app.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
                } else {
                    glfw.SetInputMode(app.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
                }
            }

            if a.key == .f3 && a.state == .pressed {
                save_screenshot(app)
            }

        case WindowResizedEvent:
            if a.size.x == 0 || a.size.y == 0 {
                app.minimized = true
                break event_loop
            }
            app.minimized = false
            app.resized = true

        case MousePositionEvent:
            delta_mouse := a.pos - mouse
            if app.mouse_locked {
                SPEED :: 100
                app.camera.euler_angles.xy += delta_mouse.yx * SPEED * f32(delta)
            }

            mouse = a.pos
        case Mouse_Scroll_Event:
            log.debugf("Scroll delta: %v", a.delta)
            app.camera.fov += a.delta.y
        }
    }

    // Check if the monitor detected any file changes
    if app.shader_monitor.triggered {
        log.info("Reloading shaders")
        app.shader_monitor.triggered = false

        path := app.shader_monitor.paths[app.shader_monitor.path_index]
        if strings.contains(path, "Object") {
            app.simple_pipeline = create_pipeline(
                &app.swapchain,
                &app.device,
                app.layout,
                app.global_descriptor_layout,
            )
        } else if strings.contains(path, "Cubemap") {
            create_cubemap_pipeline(&app.cubemap_pipeline)
        }
    }

    if delta > 0.01 {
        log.warnf("Very high delta: %v", delta)
    }

    @(static)
    time_count := f32(0.0)
    current_time := time.now()
    t := f32(time.duration_seconds(time.diff(app.start_time, current_time)))

    input := get_vector(.d, .a, .w, .s) * 1
    up_down := get_axis(.space, .left_control)
    app.camera.position.xz += ( vec4{input.x, 0, -input.y, 0} * linalg.matrix4_from_quaternion(app.camera.rotation)).xz * f32(delta)
    app.camera.position.y += up_down * f32(delta)

    app.scene_data.view_position.xyz = app.camera.position
    light := &app.scene_data.main_light
    light.position = vec4{1, 1, 1, 0}
    // light.position.y = math.sin(t * 1) * 1
    light.color = vec4{1, 1, 1, 0}

    draw_frame(app)

    flush_input()
    event_context_clear(&app.event_context)

    return false
}

@(export)
reloaded :: proc(mem: rawptr) {
    app := cast(^Application)mem
    vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
    vk.load_proc_addresses_instance(app.device.instance)

    setup_events(app.window, &app.event_context)
    // Restart background shader monitoring thread
}

@(export)
destroy :: proc(mem: rawptr) {
    app := cast(^Application)mem
    vk.DeviceWaitIdle(app.device.device)

    monitor.deinit(&app.shader_monitor)

    scene_destroy(&app.scene)

    for &buffer in app.uniform_buffers {
        buffer_destroy(&buffer)
    }
    delete(app.uniform_buffers)
    delete(app.uniform_mapped_buffers)

    image_destroy(&app.image)

    cubemap_deinit(&app.cubemap_pipeline)

    vk.DeviceWaitIdle(app.device.device)
    free_command_buffers(&app.device, app.command_buffers)
    destroy_grphics_pipeline(&app.simple_pipeline)
    vk.DestroyPipelineLayout(app.device.device, app.layout, nil)
    delete(app.descriptor_sets)
    device_destroy_descriptor_pool(&app.device, app.descriptor_pool)
    vk.DestroyDescriptorSetLayout(app.device.device, app.global_descriptor_layout, nil)
    vk.DestroyDescriptorSetLayout(app.device.device, app.material_layout, nil)
    destroy_swapchain(&app.swapchain)
    destroy_device(&app.device)

    free(app.dbg_context)
    free(app)
}

@(export)
get_size :: proc() -> int { return size_of(Application) }

save_screenshot :: proc(app: ^Application) {
    supports_blit := true

    format_properties: vk.FormatProperties
    vk.GetPhysicalDeviceFormatProperties(app.device.physical_device, app.swapchain.color_format, &format_properties)
    if .BLIT_SRC not_in format_properties.optimalTilingFeatures {
        log.infof("Device does not support blitting from optiomal tiled images")
        supports_blit = false
    }

    vk.GetPhysicalDeviceFormatProperties(app.device.physical_device, .R8G8B8A8_UNORM, &format_properties)
    if .BLIT_DST not_in format_properties.optimalTilingFeatures {
        log.infof("Device does not support blitting to linear tiled images")
        supports_blit = false
    }

    if !supports_blit {
        return
    }

    source_image := app.swapchain.swapchain_images[app.swapchain.current_frame]

    extent := app.swapchain.extent
    image := image_create(
        &app.device,
        extent.width, extent.height,
        1,
        .R8G8B8A8_UNORM,
        .LINEAR,
        {.TRANSFER_DST},
    )
    image_transition_layout(&image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

    transition_image_layout(&app.device, source_image, 1, 1, .PRESENT_SRC_KHR, .TRANSFER_SRC_OPTIMAL)

    blit_size := vk.Offset3D {
        x = i32(extent.width),
        y = i32(extent.height),
        z = 1,
    }

    blit_region := vk.ImageBlit {
        srcSubresource = vk.ImageSubresourceLayers {
            aspectMask = {.COLOR},
            layerCount = 1,
        },
        dstSubresource = vk.ImageSubresourceLayers {
            aspectMask = {.COLOR},
            layerCount = 1,
        },
    }
    blit_region.srcOffsets[1] = blit_size
    blit_region.dstOffsets[1] = blit_size

    cmd := begin_single_time_command(&app.device)
    vk.CmdBlitImage(cmd, source_image, .TRANSFER_SRC_OPTIMAL, image.handle, .TRANSFER_DST_OPTIMAL, 1, &blit_region, .LINEAR)
    end_single_time_command(&app.device, cmd)


    image_transition_layout(&image, .TRANSFER_DST_OPTIMAL, .GENERAL)
    transition_image_layout(&app.device, source_image, 1, 1, .TRANSFER_SRC_OPTIMAL, .PRESENT_SRC_KHR)

    subresource := vk.ImageSubresource {
        aspectMask = {.COLOR},
        mipLevel = 0,
        arrayLayer = 0,
    }
    subresource_layout: vk.SubresourceLayout
    vk.GetImageSubresourceLayout(app.device.device, image.handle, &subresource, &subresource_layout)

    data: rawptr
    vk.MapMemory(app.device.device, image.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &data)
    data = rawptr(uintptr(data) + uintptr(subresource_layout.offset))

    _screenshot_saver :: proc(data: rawptr) {
        work_data := cast(^Work_Data)data
        log.info("Saving screenshot")

        now := time.now()
        year, month, day := time.date(now)
        hour, min, sec := time.clock(now)
        path := fmt.ctprintf("screenshots/%v-%v-%v_%v-%v.png", year, month, day, min, sec)
        stbi.write_png(path, i32(work_data.width), i32(work_data.height), 4, work_data.data, work_data.stride)

        log.info("Finished")

        mem.free(work_data.data)
        free(work_data)
    }

    Work_Data :: struct {
        data: rawptr,
        width, height: i32,
        stride: i32,
    }
    work_data := new(Work_Data)
    work_data.data, _ = mem.alloc(int(subresource_layout.size))
    mem.copy(work_data.data, data, int(subresource_layout.size))
    work_data.width = i32(extent.width)
    work_data.height = i32(extent.height)
    work_data.stride = i32(subresource_layout.rowPitch)

    thread.run_with_data(work_data, _screenshot_saver)
}

update_uniform_buffer :: proc(app: ^Application, current_image: u32) {
    ubo := Uniform_Buffer_Object{}

    ubo.scene_data = app.scene_data

    euler := app.camera.euler_angles
    app.camera.rotation = linalg.quaternion_from_euler_angles(
        euler.x * math.RAD_PER_DEG,
        euler.y * math.RAD_PER_DEG,
        euler.z * math.RAD_PER_DEG,
        .XYZ)

    pos := app.camera.position
    trans := linalg.matrix4_translate(pos)

    // ubo.view_data.view = linalg.inverse(trans * linalg.matrix4_from_quaternion(app.camera.rotation))
    ubo.view_data.view = linalg.matrix4_from_quaternion(app.camera.rotation) * linalg.inverse(trans)
    ubo.view_data.proj = linalg.matrix4_perspective(
        linalg.to_radians(f32(app.camera.fov)),
        f32(app.swapchain.extent.width) / f32(app.swapchain.extent.height),
        0.01,
        100.0,
    )
    mem.copy(app.uniform_mapped_buffers[current_image], &ubo, size_of(ubo))

    ubo.view_data.view = linalg.matrix4_from_quaternion(app.camera.rotation)
    mem.copy(app.cubemap_pipeline.uniform_mapped_buffers[current_image], &ubo, size_of(ubo))
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

        image_info := vk.DescriptorImageInfo {
            imageLayout = .READ_ONLY_OPTIMAL,
            imageView   = app.image.view,
            sampler     = app.image.sampler,
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

create_pipeline_layout :: proc(app: ^Application) -> (layout: vk.PipelineLayout) {
    set_layouts := []vk.DescriptorSetLayout{
        app.global_descriptor_layout,
        app.material_layout,
    }

    model_constant := vk.PushConstantRange {
        offset = 0,
        size = size_of(mat4),
        stageFlags = {.VERTEX},
    }

    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType                  = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 1,
        pPushConstantRanges    = &model_constant,
        setLayoutCount         = u32(len(set_layouts)),
        pSetLayouts            = raw_data(set_layouts),
    }

    result := vk.CreatePipelineLayout(app.device.device, &pipeline_layout_create_info, nil, &layout)

    if result != vk.Result.SUCCESS {
        log.error("Failed to create pipeline layout")
    }
    return
}

create_global_descriptor_set_layout :: proc(device: ^Device) -> (layout: vk.DescriptorSetLayout) {
    ubo_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorCount = 1,
        descriptorType = vk.DescriptorType.UNIFORM_BUFFER,
        stageFlags = {.VERTEX, .FRAGMENT},
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
    global_descriptor_layout: vk.DescriptorSetLayout,
) -> (
    pipeline: Pipeline,
) {
    config := default_pipeline_config()
    config.renderpass = swapchain.renderpass
    config.layout = layout
    config.descriptor_set_layout = global_descriptor_layout
    pipeline = create_graphics_pipeline(device, config)
    return
}


vk_check :: proc(result: vk.Result, location := #caller_location) {
    if result == vk.Result.SUCCESS do return
    log.errorf("Vulkan call failed: %v %v", result, location, location = location)
}

draw_frame :: proc(app: ^Application) {
    if app.minimized do return

    image_index, err := swapchain_acquire_next_image(&app.swapchain)
    if err == .ERROR_OUT_OF_DATE_KHR || err == .SUBOPTIMAL_KHR || app.resized {
        app.resized = false
        vk.DeviceWaitIdle(app.swapchain.device.device)
        destroy_swapchain(&app.swapchain)
        // app.swapchain = create_swapchain(app.swapchain.device)
        init_swapchain(&app.device, &app.swapchain)
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
    extent := a.swapchain.extent
    viewport := vk.Viewport {
        x        = 0,
        y        = f32(extent.height),
        width    = cast(f32)extent.width,
        height   = -cast(f32)extent.height,
        minDepth = 0,
        maxDepth = 1,
    }
    vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

    scissor := vk.Rect2D {
        offset = {0, 0},
        extent = a.swapchain.extent,
    }
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

    vk.CmdBindPipeline(command_buffer, vk.PipelineBindPoint.GRAPHICS, a.cubemap_pipeline.handle)
    {

        buffers: []vk.Buffer = {a.cubemap_pipeline.buffer.handle}
        offsets: []vk.DeviceSize = {0}
        vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(buffers), raw_data(offsets))

        vk.CmdBindDescriptorSets(
            command_buffer,
            .GRAPHICS,
            a.cubemap_pipeline.pipeline_layout,
            0,
            1,
            &a.cubemap_pipeline.descriptor_sets[a.swapchain.current_frame],
            0,
            nil,
        )

        // vk.CmdDrawIndexed(command_buffer, model.num_indices, 1, 0, 0, 0)
        vk.CmdDraw(command_buffer, a.cubemap_pipeline.vertex_count, 1, 0, 0)

    }

    vk.CmdBindPipeline(command_buffer, vk.PipelineBindPoint.GRAPHICS, a.simple_pipeline.handle)
    {
        for &model in a.scene.models {
            buffers: []vk.Buffer = {model.vertex_buffer.handle}
            offsets: []vk.DeviceSize = {0}
            vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(buffers), raw_data(offsets))

            vk.CmdBindIndexBuffer(command_buffer, model.index_buffer.handle, 0, .UINT16)

            // NOTE(minebill): This probably shouldn't happen every frame, right here
            mem.copy(
                model.material.buffer,
                &model.material.block,
                size_of(Material_Block),
            )

            trans := linalg.matrix4_translate(model.translation)
            rot := linalg.matrix4_from_quaternion(model.rotation)
            model_matrix := trans * rot
            vk.CmdPushConstants(
                command_buffer,
                a.layout,
                {.VERTEX},
                0, size_of(mat4), &model_matrix,
            )

            descriptor_sets := []vk.DescriptorSet {
                a.descriptor_sets[a.swapchain.current_frame],
                model.material.descriptor_set,
            }
            vk.CmdBindDescriptorSets(
                command_buffer,
                .GRAPHICS,
                a.layout,
                0,
                u32(len(descriptor_sets)),
                raw_data(descriptor_sets),
                0,
                nil,
            )

            vk.CmdDrawIndexed(command_buffer, model.num_indices, 1, 0, 0, 0)
        }

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
        model := Model {}

        init_material(&app.device, &model.material, app.material_layout)

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
                // vertices[i].pos += node.translation
                vi += 3
                ti += 2
            }
            model.translation = node.translation

            r := node.rotation
            model.rotation = quaternion(w = r.w, x = r.x, y = r.y, z = r.z)

            accessor := primitive.indices
            data := accessor.buffer_view.buffer.data
            offset := accessor.buffer_view.offset

            indices_raw := cast([^]u16)(uintptr(data) + uintptr(offset))
            count := accessor.count
            indices := indices_raw[:count]

            model.vertex_buffer = create_vertex_buffer(&app.device, vertices)
            model.index_buffer = create_index_buffer(&app.device, indices)
            model.num_indices = u32(len(indices))

            albedo_data: []byte
            normal_map_data: []byte

            material:^gltf.material = primitive.material
            if material != nil {
                log.debugf("\tProcessing material %v", material.name)
                if material.has_pbr_metallic_roughness {
                    aa: if material.pbr_metallic_roughness.base_color_texture.texture != nil {
                        texture := material.pbr_metallic_roughness.base_color_texture.texture
                        buffer := texture.image_.buffer_view
                        color_base_data := buffer.buffer.data
                        color_offset := buffer.offset

                        size := texture.image_.buffer_view.size

                        albedo_data = (cast([^]byte)(uintptr(color_base_data) + uintptr(color_offset)))[:size]

                        texture = material.normal_texture.texture

                        // NOTE(minebill): Do proper checking here
                        if texture == nil do break aa
                        buffer = texture.image_.buffer_view
                        color_base_data = buffer.buffer.data
                        color_offset = buffer.offset

                        size = texture.image_.buffer_view.size

                        normal_map_data = (cast([^]byte)(uintptr(color_base_data) + uintptr(color_offset)))[:size]
                    }

                    model.material.albedo_color = material.pbr_metallic_roughness.base_color_factor
                    model.material.metallic_factor = material.pbr_metallic_roughness.metallic_factor
                    model.material.roughness_factor = material.pbr_metallic_roughness.roughness_factor
                }
            }
            update_material(&app.device, &model.material, albedo_data, {})
        }

        append(&scene.models, model)
    }

    return
}

scene_destroy :: proc(scene: ^Scene) {
    for &model in scene.models {
        destroy_model(&model)
    }
}

Material_Block :: struct {
    albedo_color:       vec4,
    metallic_factor:    f32,
    roughness_factor:   f32,
}

Material :: struct {
    descriptor_set:     vk.DescriptorSet,
    descriptor_pool:    vk.DescriptorPool,
    vk_buffer:          Buffer,
    buffer:             rawptr,

    albedo_image:       Image,

    normal_map_image:   Image,

    using block:        Material_Block,
}

WHITE_TEXTURE :: #load("../assets/textures/white_texture.png")
DEFAULT_NORMAL_MAP :: #load("../assets/textures/default_normal_map.png")

init_material :: proc(device: ^Device, material: ^Material, layout: vk.DescriptorSetLayout) {
    size := u32(size_of(Material_Block))
    material.vk_buffer = buffer_create(
        device,
        size,
        {.UNIFORM_BUFFER},
        {.HOST_VISIBLE, .HOST_COHERENT})

    vk.MapMemory(device.device, material.vk_buffer.memory, 0, vk.DeviceSize(size), {}, &material.buffer)

    material.descriptor_pool = device_create_descriptor_pool(device, 1, {
        {type = vk.DescriptorType.UNIFORM_BUFFER, descriptorCount = 1},
        {type = vk.DescriptorType.COMBINED_IMAGE_SAMPLER, descriptorCount = 1},
        {type = vk.DescriptorType.COMBINED_IMAGE_SAMPLER, descriptorCount = 1},
    })

    material.descriptor_set = device_allocate_descriptor_sets(
        device, 
        material.descriptor_pool, 
        1, 
        layout)[0]

    material.albedo_color = vec4{1, 1, 1, 1}
    material.metallic_factor = 0.5
    material.roughness_factor = 0.5
}

material_destroy :: proc(m: ^Material) {
    vk.UnmapMemory(m.vk_buffer.device.device, m.vk_buffer.memory)
    buffer_destroy(&m.vk_buffer)

    image_destroy(&m.albedo_image)
    image_destroy(&m.normal_map_image)

    device_destroy_descriptor_pool(m.vk_buffer.device, m.descriptor_pool)
}

update_material :: proc(device: ^Device, material: ^Material, albedo, normal_map: []byte) {

    material.albedo_image = image_load_from_memory(device, albedo if len(albedo) != 0 else WHITE_TEXTURE)
    image_view_create(&material.albedo_image, material.albedo_image.format, {.COLOR})

    material.normal_map_image = image_load_from_memory(device, normal_map if len(normal_map) != 0 else WHITE_TEXTURE)
    image_view_create(&material.normal_map_image, material.albedo_image.format, {.COLOR})

    buffer_info := vk.DescriptorBufferInfo {
        buffer = material.vk_buffer.handle,
        offset = 0,
        range  = size_of(Material_Block),
    }

    image_info := vk.DescriptorImageInfo {
        imageLayout = .READ_ONLY_OPTIMAL,
        imageView   = material.albedo_image.view,
        sampler     = material.albedo_image.sampler,
    }

    normal_map_info := vk.DescriptorImageInfo {
        imageLayout = .READ_ONLY_OPTIMAL,
        imageView   = material.normal_map_image.view,
        sampler     = material.normal_map_image.sampler,
    }

    descriptor_writes := []vk.WriteDescriptorSet {
         {
            sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
            dstSet = material.descriptor_set,
            dstBinding = 0,
            dstArrayElement = 0,
            descriptorType = .UNIFORM_BUFFER,
            descriptorCount = 1,
            pBufferInfo = &buffer_info,
        },
         {
            sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
            dstSet = material.descriptor_set,
            dstBinding = 1,
            dstArrayElement = 0,
            descriptorType = .COMBINED_IMAGE_SAMPLER,
            descriptorCount = 1,
            pImageInfo = &image_info,
        },
    }

    vk.UpdateDescriptorSets(
        device.device,
        u32(len(descriptor_writes)),
        raw_data(descriptor_writes),
        0,
        nil,
    )

    return
}

create_material_set_layout :: proc(device: ^Device) -> (layout: vk.DescriptorSetLayout) {
    material_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorCount = 1,
        descriptorType = vk.DescriptorType.UNIFORM_BUFFER,
        stageFlags = {.FRAGMENT},
    }

    albedo_texture_binding := vk.DescriptorSetLayoutBinding {
        binding = 1,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        stageFlags = {.FRAGMENT},
        pImmutableSamplers = nil,
    }

    normal_map_binding := vk.DescriptorSetLayoutBinding {
        binding = 2,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        stageFlags = {.FRAGMENT},
        pImmutableSamplers = nil,
    }

    // environment_texture_binding := vk.DescriptorSetLayoutBinding {
    //     binding = 2,
    //     descriptorCount = 1,
    //     descriptorType = .COMBINED_IMAGE_SAMPLER,
    //     stageFlags = {.FRAGMENT},
    //     pImmutableSamplers = nil,
    // }

    bindings := []vk.DescriptorSetLayoutBinding {
        material_layout_binding,
        albedo_texture_binding,
        normal_map_binding,
        // environment_texture_binding,
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType        = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(bindings)),
        pBindings    = raw_data(bindings),
    }

    vk_check(vk.CreateDescriptorSetLayout(device.device, &layout_info, nil, &layout))
    return
}


Model :: struct {
    vertex_buffer:  Buffer,
    index_buffer:   Buffer,

    translation: vec3,
    rotation: quaternion128,
    // image:          Image,
    // image_view:     Image_View,

    num_indices:    u32,
    material:       Material,
    buffer:         Buffer,
    buffer_map:     rawptr,
}

destroy_model :: proc(model: ^Model) {
    material_destroy(&model.material)
    buffer_destroy(&model.vertex_buffer)
    buffer_destroy(&model.index_buffer)
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
