package main

import sdl "vendor:sdl2"
import nk "packages:odin-nuklear"
import vk "vendor:vulkan"
import "core:mem"
import tracy "packages:odin-tracy"
import "core:math/linalg"
import vma "packages:odin-vma"

MAX_VERTEX_BUFFER :: 512 * 1024
MAX_INDEX_BUFFER :: 128 * 1024
MAX_TEXTURES :: 256

Nuklear :: struct {
    window: ^sdl.Window,
    device: ^Device,
    atlas: nk.Font_Atlas,
    ctx: nk.Context,

    pipeline: Nuklear_Pipeline,
    font_image: Image,

    cmds: nk.Buffer,

    sampler: vk.Sampler,
    null_texutre: nk.Draw_Null_Texture,
}

Nuklear_Descriptor_Set :: struct {
    set:    vk.DescriptorSet,
    view:   vk.ImageView,
}

Nuklear_Pipeline :: struct {
    using pipeline: Pipeline,
    swapchain: ^Swapchain,

    pipeline_layout:    vk.PipelineLayout,
    descriptor_sets:    []vk.DescriptorSet,
    descriptor_layout:  vk.DescriptorSetLayout,
    texture_set_layout: vk.DescriptorSetLayout,
    texture_sets:       []Nuklear_Descriptor_Set,
    descriptor_pool:    vk.DescriptorPool,

    uniform_buffers:        []Buffer,
    uniform_mapped_buffers: []rawptr,

    vertex_buffer: Buffer,
    vertex_mapped: rawptr,

    index_buffer: Buffer,
    index_mapped: rawptr,
}

nuklear_init :: proc(n: ^Nuklear, device: ^Device, window: ^sdl.Window, swapchain: ^Swapchain) {
    nk.init_default(&n.ctx, nil)
    n.window = window
    n.device = device
    n.ctx.clip.copy  = nk_clipboard_copy
    n.ctx.clip.paste = nk_clipboard_paste

    n.pipeline.device    = device
    n.pipeline.swapchain = swapchain

    n.pipeline.descriptor_layout  = nuklear_create_descriptor_set_layout(device)
    n.pipeline.texture_set_layout = nuklear_create_texture_set_layout(device)

    n.pipeline.vertex_buffer = buffer_create(device, MAX_VERTEX_BUFFER, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
    buffer_map(&n.pipeline.vertex_buffer, &n.pipeline.vertex_mapped)
    n.pipeline.index_buffer  = buffer_create(device, MAX_INDEX_BUFFER, {.INDEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
    buffer_map(&n.pipeline.index_buffer, &n.pipeline.index_mapped)

    nk.buffer_init_default(&n.cmds)

    n.pipeline.descriptor_pool = device_create_descriptor_pool(device, MAX_TEXTURES + 1, {
        {type = vk.DescriptorType.UNIFORM_BUFFER, descriptorCount = 1},
        {type = vk.DescriptorType.COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_TEXTURES},
    })

    n.pipeline.descriptor_sets = device_allocate_descriptor_sets(
        device,
        n.pipeline.descriptor_pool,
        1,
        n.pipeline.descriptor_layout,
    )

    n.sampler = image_sampler_create(device)

    nuklear_allocate_texture_descriptor_sets(n)

    layouts := []vk.DescriptorSetLayout {
        n.pipeline.descriptor_layout,
        n.pipeline.texture_set_layout,
    }

    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType                  = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 0,
        setLayoutCount         = u32(len(layouts)),
        pSetLayouts            = raw_data(layouts),
    }

    vk_check(vk.CreatePipelineLayout(device.device, &pipeline_layout_create_info, nil, &n.pipeline.pipeline_layout))

    nuklear_cubemap_pipeline(&n.pipeline)

    n.pipeline.uniform_buffers = make([]Buffer, MAX_FRAMES_IN_FLIGHT)
    n.pipeline.uniform_mapped_buffers = make([]rawptr, MAX_FRAMES_IN_FLIGHT)

    for i in 0 ..< 1 {
        size := u32(size_of(mat4))
        n.pipeline.uniform_buffers[i] = buffer_create(
            device,
            size,
            {.UNIFORM_BUFFER},
            {.HOST_VISIBLE, .HOST_COHERENT},
        )

        // vk.0MapMemory(
        //     pipeline.device.device,
        //     0,
        //     vk.DeviceSize(size),
        //     {},
        // )

        buffer_map(
            &n.pipeline.uniform_buffers[i],
            &n.pipeline.uniform_mapped_buffers[i],
        )

        buffer_info := vk.DescriptorBufferInfo {
            buffer = n.pipeline.uniform_buffers[i].handle,
            offset = 0,
            range  = size_of(mat4),
        }

        // image_info := vk.DescriptorImageInfo {
        //     imageLayout = .READ_ONLY_OPTIMAL,
        //     imageView   = pipeline.image.view,
        //     sampler     = pipeline.image.sampler,
        // }

        descriptor_writes := []vk.WriteDescriptorSet {
             {
                sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                dstSet = n.pipeline.descriptor_sets[i],
                dstBinding = 0,
                dstArrayElement = 0,
                descriptorType = .UNIFORM_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &buffer_info,
            },
            //  {
            //     sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
            //     dstSet = pipeline.descriptor_sets[i],
            //     dstBinding = 1,
            //     dstArrayElement = 0,
            //     descriptorType = .COMBINED_IMAGE_SAMPLER,
            //     descriptorCount = 1,
            //     pImageInfo = &image_info,
            // },
        }

        vk.UpdateDescriptorSets(
            device.device,
            u32(len(descriptor_writes)),
            raw_data(descriptor_writes),
            0,
            nil,
        )
    }
}

nuklear_draw :: proc(n: ^Nuklear, cmd: vk.CommandBuffer) {
    tracy.ZoneN("Nuklear Render")

    w := cast(f32)n.pipeline.swapchain.extent.width
    h := cast(f32)n.pipeline.swapchain.extent.height

    projection := mat4{
        2.0 /w ,  0.0,  0.0, 0.0,
        0.0, -2.0 / h ,  0.0, 0.0,
        0.0,  0.0, -1.0, 0.0,
       -1.0,  1.0,  0.0, 1.0,
    }

    // projection[0][0] /= cast(f32)n.pipeline.swapchain.extent.width
    // projection[1][1] /= cast(f32)n.pipeline.swapchain.extent.height

    // projection = linalg.matrix_ortho3d_f32(-2, 2, -2, 2, -1, 1)

    mem.copy(n.pipeline.uniform_mapped_buffers[0], &projection, size_of(mat4))

    c := &n.ctx
    vk.CmdBindPipeline(cmd, vk.PipelineBindPoint.GRAPHICS, n.pipeline.handle)
    {
        vk.CmdBindDescriptorSets(
            cmd,
            .GRAPHICS,
            n.pipeline.pipeline_layout, 0, 1,
            &n.pipeline.descriptor_sets[0], 0, nil,
        )

        config: nk.Convert_Config
        vertex_layout := []nk.Draw_Vertex_Layout_Element {
            {.Position, .Float, cast(i64)offset_of(NkVertex, position)},
            {.Texcoord, .Float, cast(i64)offset_of(NkVertex, uv)},
            {.Color, .R8G8B8A8, cast(i64)offset_of(NkVertex, col)},
            {max(nk.Draw_Vertex_Layout_Attribute), nk.Draw_Vertex_Layout_Format(19), 0},
        }

        config.vertex_layout = raw_data(vertex_layout)
        config.vertex_size = size_of(NkVertex)
        config.vertex_alignment = align_of(NkVertex)
        config.tex_null = n.null_texutre
        config.circle_segment_count = 22
        config.curve_segment_count = 22
        config.arc_segment_count = 22
        config.global_alpha = 1.0
        config.shape_aa = .On
        config.line_aa = .On

        vbuf: nk.Buffer
        nk.buffer_init_fixed(&vbuf, n.pipeline.vertex_mapped, MAX_VERTEX_BUFFER)

        ibuf: nk.Buffer
        nk.buffer_init_fixed(&ibuf, n.pipeline.index_mapped, MAX_INDEX_BUFFER)

        nk.convert(c, &n.cmds, &vbuf, &ibuf, &config)

        offset := vk.DeviceSize(0)
        vk.CmdBindVertexBuffers(cmd, 0, 1, &n.pipeline.vertex_buffer.handle, &offset)
        vk.CmdBindIndexBuffer(cmd, n.pipeline.index_buffer.handle, 0, .UINT16)

        current_texture: vk.ImageView
        index_offset: u32 = 0
        for command := nk._draw_begin(c, &n.cmds); command != nil; command = nk._draw_next(command, &n.cmds, c) {
            if command.texture.ptr == nil {
                continue
            }
            
            img := (transmute(^vk.ImageView)command.texture.ptr)^
            if img != 0 && img != current_texture {
                found := false
                set_index := 0
                
                for set, i in n.pipeline.texture_sets {
                    if set.view == img {
                        found = true
                        set_index = i
                        break
                    }
                }

                if !found {
                    nuklear_update_texture_set(n, &n.pipeline.texture_sets[set_index], img)
                }

                vk.CmdBindDescriptorSets(
                    cmd,
                    .GRAPHICS,
                    n.pipeline.pipeline_layout, 1, 1,
                    &n.pipeline.texture_sets[set_index].set, 0, nil,
                )
            }

            if command.elem_count == 0 {
                continue
            }

            scissor := vk.Rect2D {
                offset = {
                    x = max(cast(i32)command.clip_rect.x, 0),
                    y = max(cast(i32)command.clip_rect.y, 0),
                },
                extent = {
                    width = u32(command.clip_rect.w),
                    height = u32(command.clip_rect.h),
                },
            }

            vk.CmdSetScissor(cmd, 0, 1, &scissor)
            vk.CmdDrawIndexed(cmd, command.elem_count, 1, index_offset, 0, 0)
            index_offset += command.elem_count
        }
        nk.clear(c)
    }
}

nk_handle_event :: proc(n: ^Nuklear, event: sdl.Event) {
    c := &n.ctx

    if c.input.mouse.grab == 1 {
        sdl.SetRelativeMouseMode(true)
        c.input.mouse.grab = 0
    } else if c.input.mouse.ungrab == 1 {

        sdl.SetRelativeMouseMode(false)
        c.input.mouse.ungrab = 0
    }

    #partial switch event.type {
    case .KEYUP, .KEYDOWN:
        down := cast(nk.Bool)(event.type == .KEYDOWN)
        state := sdl.GetKeyboardState(nil)
        #partial switch event.key.keysym.sym
        {
            case .RSHIFT: /* RSHIFT & LSHIFT share same routine */
            case .LSHIFT:    nk.input_key(c, .Shift, down)
            case .DELETE:    nk.input_key(c, .Del, down)
            case .RETURN:    nk.input_key(c, .Enter, down)
            case .TAB:       nk.input_key(c, .Tab, down)
            case .BACKSPACE: nk.input_key(c, .Backspace, down)
            case .HOME:      nk.input_key(c, .Text_Start, down)
                             nk.input_key(c, .Scroll_Start, down)
            case .END:       nk.input_key(c, .Text_End, down)
                             nk.input_key(c, .Scroll_End, down)
            case .PAGEDOWN:  nk.input_key(c, .Scroll_Down, down)
            case .PAGEUP:    nk.input_key(c, .Scroll_Up, down)
            case .z:         nk.input_key(c, .Text_Undo, down       && cast(b32)state[sdl.Scancode.LCTRL])
            case .r:         nk.input_key(c, .Text_Redo, down       && cast(b32)state[sdl.Scancode.LCTRL])
            case .c:         nk.input_key(c, .Copy, down            && cast(b32)state[sdl.Scancode.LCTRL])
            case .v:         nk.input_key(c, .Paste, down           && cast(b32)state[sdl.Scancode.LCTRL])
            case .x:         nk.input_key(c, .Cut, down             && cast(b32)state[sdl.Scancode.LCTRL])
            case .b:         nk.input_key(c, .Text_Line_Start, down && cast(b32)state[sdl.Scancode.LCTRL])
            case .e:         nk.input_key(c, .Text_Line_End, down   && cast(b32)state[sdl.Scancode.LCTRL])
            case .UP:        nk.input_key(c, .Up, down)
            case .DOWN:      nk.input_key(c, .Down, down)
            case .LEFT:
                if cast(b32)state[sdl.Scancode.LCTRL] {
                    nk.input_key(c, .Text_Word_Left, down)
                } else {
                    nk.input_key(c, .Left, down)
                }
            case .RIGHT:
                if cast(b32)state[sdl.Scancode.LCTRL] {
                    nk.input_key(c, .Text_Word_Right, down)
                }
                else {
                    nk.input_key(c, .Right, down)
                }
        }

    case .MOUSEBUTTONUP: /* MOUSEBUTTONUP & MOUSEBUTTONDOWN share same routine */
    case .MOUSEBUTTONDOWN:
        x := event.button.x
        y := event.button.y
        down := b32(event.type == .MOUSEBUTTONDOWN)
        switch event.button.button
        {
            case sdl.BUTTON_LEFT:
                if event.button.clicks > 1 {
                    nk.input_button(c, .Double, x, y, down)
                }else {
                    nk.input_button(c, .Left, x, y, down)
                }
            case sdl.BUTTON_MIDDLE: nk.input_button(c, .Middle, x, y, down)
            case sdl.BUTTON_RIGHT:  nk.input_button(c, .Right, x, y, down)
        }

    case .MOUSEMOTION:
        if c.input.mouse.grabbed == 1 {
            x := c.input.mouse.prev.x
            y := c.input.mouse.prev.y
            nk.input_motion(c, i32(x) + event.motion.xrel, i32(y) + event.motion.yrel)
        }
        else {
            nk.input_motion(c, event.motion.x, event.motion.y)
        }

    case .TEXTINPUT:
        glyph: rune

        // mem.copy(glyph, event.text.text, NK_UTF_SIZE);
        // nk.input_glyph(c, glyph);

    case .MOUSEWHEEL:
        nk.input_scroll(c, [2]f32{f32(event.wheel.x), f32(event.wheel.y)});
    }
}

nk_clipboard_paste :: proc "c" (handle: nk.Handle, text_edit: ^nk.Text_Edit) {
    text := sdl.GetClipboardText()
    if text != nil {
        nk.textedit_paste(text_edit, text, cast(i32)len(text));
    }
    // (void)usr;
}

nk_clipboard_copy ::proc "c" (handle: nk.Handle, text: cstring, len: i32)
{
    // char *str = 0;
    // if (!len) return;
    // str = (char*)malloc((size_t)len+1);
    // if (!str) return;
    // memcpy(str, text, (size_t)len);
    // str[len] = '\0';
    // SDL_SetClipboardText(str);
    // free(str);
}

nk_font_stash_begin :: proc(n: ^Nuklear, atlas: ^^nk.Font_Atlas) {
    nk.font_atlas_init_default(&n.atlas)
    nk.font_atlas_begin(&n.atlas)
    atlas^ = &n.atlas
}


nk_font_stash_end ::proc (n: ^Nuklear) {
    // const void *image; int w, h;
    image_raw: [^]byte
    w: i32
    h: i32

    image_raw = cast([^]byte)nk.font_atlas_bake(&n.atlas, &w, &h, .RGBA32)

    image := image_raw[:w * h * 4]
    n.font_image = image_load_from_memory_raw(n.device, image, w, h)
    image_view_create(&n.font_image, n.font_image.format, {.COLOR})
    nk.font_atlas_end(&n.atlas, nk.handle_ptr(&n.font_image.view), &n.null_texutre);
    if n.atlas.default_font != nil {
        nk.style_set_font(&n.ctx, &n.atlas.default_font.handle)
    }
}

nuklear_create_descriptor_set_layout :: proc(device: ^Device) -> (layout: vk.DescriptorSetLayout) {
    ubo_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorCount = 1,
        descriptorType = vk.DescriptorType.UNIFORM_BUFFER,
        stageFlags = {.VERTEX},
    }

    bindings := []vk.DescriptorSetLayoutBinding {
        ubo_layout_binding,
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType        = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(bindings)),
        pBindings    = raw_data(bindings),
    }

    vk_check(vk.CreateDescriptorSetLayout(device.device, &layout_info, nil, &layout))
    return
}

nuklear_create_texture_set_layout :: proc(device: ^Device) -> (layout: vk.DescriptorSetLayout) {
    ubo_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorCount = 1,
        descriptorType = vk.DescriptorType.COMBINED_IMAGE_SAMPLER,
        stageFlags = {.FRAGMENT},
    }

    bindings := []vk.DescriptorSetLayoutBinding {
        ubo_layout_binding,
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType        = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = u32(len(bindings)),
        pBindings    = raw_data(bindings),
    }

    vk_check(vk.CreateDescriptorSetLayout(device.device, &layout_info, nil, &layout))
    return
}

nuklear_cubemap_pipeline :: proc(pipeline: ^Nuklear_Pipeline) {
    config := default_pipeline_config()
    config.renderpass = pipeline.swapchain.renderpass
    config.layout = pipeline.pipeline_layout
    config.descriptor_set_layout = pipeline.descriptor_layout

    // log.debugf("len(descriptor_sets): %v", len(pipeline.descriptor_sets))

    pipeline.shader = create_shader(
        pipeline.device,
        "bin/assets/shaders/nuklear.spv",
    )
    // pipeline.shader.pipeline = &pipeline

    vert_stage_create_info := vk.PipelineShaderStageCreateInfo {
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.VERTEX},
        module = pipeline.shader.fragment_module,
        pName = "main",
    }

    frag_stage_create_info := vk.PipelineShaderStageCreateInfo {
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.FRAGMENT},
        module = pipeline.shader.fragment_module,
        pName = "main",
    }

    stages := []vk.PipelineShaderStageCreateInfo{vert_stage_create_info, frag_stage_create_info}

    binding_descriptions: []vk.VertexInputBindingDescription = {nuklear_vertex_binding_description()}
    attribute_descriptions := nuklear_vertex_attribute_descriptions()

    vertex_pipeline := vk.PipelineVertexInputStateCreateInfo {
        sType                           = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount   = u32(len(binding_descriptions)),
        pVertexBindingDescriptions      = raw_data(binding_descriptions),
        vertexAttributeDescriptionCount = u32(len(attribute_descriptions)),
        pVertexAttributeDescriptions    = raw_data(attribute_descriptions[:]),
    }

    input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
        sType                  = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology               = vk.PrimitiveTopology.TRIANGLE_LIST,
        primitiveRestartEnable = false,
    }

    dynamic_states := []vk.DynamicState{vk.DynamicState.VIEWPORT, vk.DynamicState.SCISSOR}

    dyn_state_create_info := vk.PipelineDynamicStateCreateInfo {
        sType             = vk.StructureType.PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        pDynamicStates    = raw_data(dynamic_states),
        dynamicStateCount = cast(u32)len(dynamic_states),
    }

    rasterizer_create_info := config.rasterization_info
    multisampling_create_info := config.multisample_info
    multisampling_create_info.rasterizationSamples = device_get_max_usable_sample_count(pipeline.device)
    color_blending := config.colorblend_info
    color_blending.pAttachments = &config.colorblend_attachment_info

    viewport := config.viewport
    scissor := config.scissor
    viewport_state_create_info := vk.PipelineViewportStateCreateInfo {
        sType         = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports    = &viewport,
        scissorCount  = 1,
        pScissors     = &scissor,
    }

    depth_stencil_create_info := vk.PipelineDepthStencilStateCreateInfo {
        sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable       = false,
        depthWriteEnable      = true,
        depthCompareOp        = .LESS,
        depthBoundsTestEnable = false,
        stencilTestEnable     = false,
    }

    pipeline_create_info := vk.GraphicsPipelineCreateInfo {
        sType               = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount          = 2,
        pStages             = raw_data(stages),
        pVertexInputState   = &vertex_pipeline,
        pInputAssemblyState = &input_assembly,
        pViewportState      = &viewport_state_create_info,
        pRasterizationState = &rasterizer_create_info,
        pMultisampleState   = &multisampling_create_info,
        pDepthStencilState  = &depth_stencil_create_info,
        pColorBlendState    = &color_blending,
        pDynamicState       = &dyn_state_create_info,
        layout              = config.layout,
        renderPass          = config.renderpass,
        subpass             = 0,
        basePipelineHandle  = 0,
        basePipelineIndex   = -1,
    }

    vk_check(vk.CreateGraphicsPipelines(
        pipeline.device.device,
        0,
        1,
        &pipeline_create_info,
        nil,
        &pipeline.handle,
    ))
    pipeline.config = config
    return
}

NkVertex :: struct {
    position: vec2,
    uv: vec2,
    col: [4]u8,
}

nuklear_vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
    return {
        binding = 0, 
        stride = size_of(NkVertex), 
        inputRate = vk.VertexInputRate.VERTEX,
    }
}

nuklear_vertex_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
    return {
        {
            binding = 0,
            location = 0,
            format = vk.Format.R32G32_SFLOAT,
            offset = u32(offset_of(NkVertex, position)),
        },
        {
            binding = 0,
            location = 1,
            format = vk.Format.R32G32_SFLOAT,
            offset = u32(offset_of(NkVertex, uv)),
        },
        {
            binding = 0,
            location = 2,
            format = vk.Format.R8G8B8A8_UINT,
            offset = u32(offset_of(NkVertex, col)),
        },
   }
}

nuklear_allocate_texture_descriptor_sets :: proc(n: ^Nuklear) {
    sets := make([]vk.DescriptorSet, MAX_TEXTURES, context.temp_allocator)
    layouts := make([]vk.DescriptorSetLayout, MAX_TEXTURES, context.temp_allocator)
    n.pipeline.texture_sets = make([]Nuklear_Descriptor_Set, MAX_TEXTURES)

    for i := 0; i < MAX_TEXTURES; i += 1 {
        layouts[i] = n.pipeline.texture_set_layout
    }

    alloc_info := vk.DescriptorSetAllocateInfo {
        sType              = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = n.pipeline.descriptor_pool,
        descriptorSetCount = MAX_TEXTURES,
        pSetLayouts        = raw_data(layouts),
    }

    vk_check(vk.AllocateDescriptorSets(n.device.device, &alloc_info, raw_data(sets)))

    for i := 0; i < MAX_TEXTURES; i += 1 {
        n.pipeline.texture_sets[i].set = sets[i]
    }
}

nuklear_update_texture_set :: proc(n: ^Nuklear, set: ^Nuklear_Descriptor_Set, view: vk.ImageView) {
    set.view = view

    image_info := vk.DescriptorImageInfo {
        sampler = n.sampler,
        imageView = view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }

    write := vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = set.set,
        dstBinding = 0,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &image_info,
    }

    vk.UpdateDescriptorSets(n.device.device, 1, &write, 0, nil)
}
