package main
import vk "vendor:vulkan"
import "core:log"
import "core:mem"
import "core:math/linalg"
import "core:math"

SHADOW_MAP_WIDTH :: 2048
SHADOW_MAP_HEIGHT :: 2048

Shadow_Pipeline :: struct {
    using pipeline: Pipeline,
    swapchain:          ^Swapchain,

    pipeline_layout:    vk.PipelineLayout,
    descriptor_sets:    []vk.DescriptorSet,
    descriptor_layout:  vk.DescriptorSetLayout,
    descriptor_pool:    vk.DescriptorPool,
}

Shadow_Pass :: struct {
    device: ^Device,
    pipeline: Shadow_Pipeline,

    render_pass:        vk.RenderPass,
    framebuffer:        vk.Framebuffer,
    color_image:        Image,
    framebuffer_image:  Image,
}

shadow_pass_init :: proc(s: ^Shadow_Pass, device: ^Device, swapchain: ^Swapchain) {
    s.device = device
    s.pipeline.device = device
    s.pipeline.swapchain = swapchain

    s.pipeline.descriptor_layout = device_create_descriptor_set_layout(device, {
        {
            binding = 0,
            descriptorCount = 1,
            descriptorType = vk.DescriptorType.UNIFORM_BUFFER,
            stageFlags = {.VERTEX},
        },
        {
            binding = 1,
            descriptorCount = 1,
            descriptorType = .COMBINED_IMAGE_SAMPLER,
            stageFlags = {.FRAGMENT},
            pImmutableSamplers = nil,
        },
    })

    s.pipeline.descriptor_pool = device_create_descriptor_pool(s.pipeline.device, MAX_FRAMES_IN_FLIGHT, {
        {type = vk.DescriptorType.UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
        {type = vk.DescriptorType.COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
    })

    format := find_supported_format(
        swapchain.device,
        {.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT},
        .OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT},
    )

    shadow_pass_create_render_pass(s, format)

    s.framebuffer_image = image_create(
        device,
        SHADOW_MAP_WIDTH,
        SHADOW_MAP_HEIGHT,
        1,
        format,
        .OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        samples = {._1},
    )
    s.framebuffer_image.sampler = image_sampler_create(device, 1, 0)
    image_view_create(&s.framebuffer_image, format, {.DEPTH})

    s.color_image = image_create(
        device,
        SHADOW_MAP_WIDTH,
        SHADOW_MAP_HEIGHT,
        1,
        .R8G8B8A8_SRGB,
        .LINEAR,
        {.COLOR_ATTACHMENT, .SAMPLED},
        samples = {._1},
    )
    s.color_image.sampler = image_sampler_create(device, 1, 0)
    image_view_create(&s.color_image, s.color_image.format, {.COLOR})
    image_transition_layout(&s.color_image, .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL)

    attachments := []vk.ImageView {
        s.color_image.view,
        s.framebuffer_image.view,
    }

    framebuffer_info := vk.FramebufferCreateInfo {
        sType           = .FRAMEBUFFER_CREATE_INFO,
        renderPass      = s.render_pass,
        attachmentCount = u32(len(attachments)),
        pAttachments    = raw_data(attachments),
        width           = SHADOW_MAP_WIDTH,
        height          = SHADOW_MAP_HEIGHT,
        layers          = 1,
    }
    vk_check(vk.CreateFramebuffer(
        device.device,
        &framebuffer_info,
        nil,
        &s.framebuffer,
    ))


    push_ranges := []vk.PushConstantRange {
        {
            offset = 0,
            size = size_of(mat4) * 2,
            stageFlags = {.VERTEX},
        },
    }

    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType                  = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = u32(len(push_ranges)),
        pPushConstantRanges    = raw_data(push_ranges),
        setLayoutCount         = 1,
        pSetLayouts            = &s.pipeline.descriptor_layout,
    }

    vk_check(vk.CreatePipelineLayout(s.pipeline.device.device, &pipeline_layout_create_info, nil, &s.pipeline.pipeline_layout))

    shadow_pass_create_pipeline(s)
}

shadow_pass_deinit :: proc(s: ^Shadow_Pass) {
    shadow_pass_pipeline_deinit(&s.pipeline)

    image_destroy(&s.color_image)
    image_destroy(&s.framebuffer_image)

    vk.DestroyFramebuffer(s.device.device, s.framebuffer, nil)
    vk.DestroyRenderPass(s.device.device, s.render_pass, nil)
}

@(private = "file")
shadow_pass_pipeline_deinit :: proc(s: ^Shadow_Pipeline) {
    device_destroy_descriptor_pool(s.device, s.descriptor_pool)

    vk.DestroyDescriptorSetLayout(s.device.device, s.descriptor_layout, nil)
    vk.DestroyPipelineLayout(s.device.device, s.pipeline_layout, nil)
    destroy_grphics_pipeline(s)
}

shadow_pass :: proc(s: ^Shadow_Pass, cmd: vk.CommandBuffer) {
    clear_values := []vk.ClearValue {
        {},
        {depthStencil = {1, 0}},
    }

    render_pass_info := vk.RenderPassBeginInfo {
        sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
        renderPass = s.render_pass,
        framebuffer = s.framebuffer,
        renderArea = vk.Rect2D{
            offset = {0, 0},
            extent = {
                width = SHADOW_MAP_WIDTH,
                height = SHADOW_MAP_HEIGHT,
            },
        },
        clearValueCount = u32(len(clear_values)),
        pClearValues = raw_data(clear_values),
    }

    vk.CmdBeginRenderPass(cmd, &render_pass_info, vk.SubpassContents.INLINE)
    // image_transition_layout(&s.color_image, .SHADER_READ_ONLY_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL)
    defer {
        vk.CmdEndRenderPass(cmd)
        // image_transition_layout(&s.color_image, .COLOR_ATTACHMENT_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
    }

    viewport := vk.Viewport {
        x        = 0,
        y        = SHADOW_MAP_HEIGHT,
        width    = cast(f32)SHADOW_MAP_WIDTH,
        height   = -cast(f32)SHADOW_MAP_HEIGHT,
        minDepth = 0,
        maxDepth = 1,
    }
    vk.CmdSetViewport(cmd, 0, 1, &viewport)

    scissor := vk.Rect2D {
        offset = {0, 0},
        extent = {
            width = SHADOW_MAP_WIDTH,
            height = SHADOW_MAP_HEIGHT,
        },
    }
    vk.CmdSetScissor(cmd, 0, 1, &scissor)

    vk.CmdBindPipeline(cmd, vk.PipelineBindPoint.GRAPHICS, s.pipeline.handle)
    for &model in g_app.scene.models {
        buffers: []vk.Buffer = {model.vertex_buffer.handle}
        offsets: []vk.DeviceSize = {0}
        vk.CmdBindVertexBuffers(cmd, 0, 1, raw_data(buffers), raw_data(offsets))

        vk.CmdBindIndexBuffer(cmd, model.index_buffer.handle, 0, .UINT16)

        // NOTE(minebill):  This probably shouldn't happen every frame, right here
        //                  but i do this anyway in case the material changes.
        mem.copy(
            model.material.buffer,
            &model.material.block,
            size_of(Material_Block),
        )

        trans := linalg.matrix4_translate(model.translation)
        rot := linalg.matrix4_from_quaternion(model.rotation)
        model_matrix := trans * rot

        light_proj := linalg.matrix_ortho3d_f32(
            -10, 10, -10, 10, g_app.near_far[0], g_app.near_far[1],
        )
        // light_proj := linalg.matrix4_perspective(linalg.to_radians(f32(45.0)), 1, g_app.near_far[0], g_app.near_far[1])

        pos := g_app.scene_data.view_position.rgb + vec3{20, 20, 00}
        light_view := linalg.matrix4_look_at_f32(
            pos,
            pos + g_app.scene_data.main_light.direction.xyz,
            vec3{0, 1, 0},
        )

        g_app.scene_data.main_light.light_space_matrix = light_proj * light_view

        // matrices := [2]mat4 {
        //     model_matrix,
        //     light_space_matrix,
        // }
        size := size_of(mat4) * 2
        // buffer, _ := mem.alloc(size, allocator = context.temp_allocator)
        // mem.copy(buffer, &model_matrix, size_of(mat4))
        // mem.copy(mem.ptr_offset(&buffer, size_of(mat4)), &light_space_matrix, size_of(mat4))
        matrices := make([]mat4, 2, allocator = context.temp_allocator)
        matrices[0] = model_matrix
        matrices[1] = g_app.scene_data.main_light.light_space_matrix

        vk.CmdPushConstants(
            cmd,
            s.pipeline.pipeline_layout,
            {.VERTEX},
            0, size_of(mat4) * 2, raw_data(matrices),
        )

        // vk.CmdPushConstants(
        //     cmd,
        //     g_app.layout,
        //     {.VERTEX},
        //     size_of(mat4), size_of(mat4), &light_space_matrix,
        // )

        // descriptor_sets := []vk.DescriptorSet {
        //     g_app.descriptor_sets[g_app.swapchain.current_frame],
        //     model.material.descriptor_set,
        // }
        // vk.CmdBindDescriptorSets(
        //     cmd,
        //     .GRAPHICS,
        //     g_app.layout,
        //     0,
        //     u32(len(descriptor_sets)),
        //     raw_data(descriptor_sets),
        //     0,
        //     nil,
        // )

        vk.CmdDrawIndexed(cmd, model.num_indices, 1, 0, 0, 0)
    }
}

shadow_pass_create_render_pass :: proc(s: ^Shadow_Pass, format: vk.Format) {
    samples := device_get_max_usable_sample_count(s.device)
    color_attachment := vk.AttachmentDescription {
        format = .R8G8B8A8_SRGB,
        samples = {._1},
        loadOp = vk.AttachmentLoadOp.CLEAR,
        storeOp = vk.AttachmentStoreOp.STORE,
        stencilLoadOp = vk.AttachmentLoadOp.DONT_CARE,
        stencilStoreOp = vk.AttachmentStoreOp.DONT_CARE,
        initialLayout = vk.ImageLayout.UNDEFINED,
        finalLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
    }

    depth_attachment := vk.AttachmentDescription {
        format = format,
        samples = {._1},
        loadOp = .CLEAR,
        storeOp = .STORE,
        stencilLoadOp = .DONT_CARE,
        stencilStoreOp = .DONT_CARE,
        initialLayout = .UNDEFINED,
        finalLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    }

    color_attachment_ref := vk.AttachmentReference {
        attachment = 0,
        layout     = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
    }

    depth_attachment_ref := vk.AttachmentReference {
        attachment = 1,
        layout     = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    }

    subpass := vk.SubpassDescription {
        pipelineBindPoint       = vk.PipelineBindPoint.GRAPHICS,
        colorAttachmentCount    = 1,
        pDepthStencilAttachment = &depth_attachment_ref,
        pColorAttachments       = &color_attachment_ref,
    }

    dependency := vk.SubpassDependency {
        srcSubpass = vk.SUBPASS_EXTERNAL,
        dstSubpass = 0,
        srcStageMask = {vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
        srcAccessMask = {vk.AccessFlag.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstStageMask = {vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
        dstAccessMask = {vk.AccessFlag.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    }

    attachments := []vk.AttachmentDescription{color_attachment, depth_attachment}

    render_pass_create_info := vk.RenderPassCreateInfo {
        sType           = vk.StructureType.RENDER_PASS_CREATE_INFO,
        attachmentCount = u32(len(attachments)),
        pAttachments    = raw_data(attachments),
        subpassCount    = 1,
        pSubpasses      = &subpass,
        dependencyCount = 1,
        pDependencies   = &dependency,
    }

    result := vk.CreateRenderPass(
        s.device.device,
        &render_pass_create_info,
        nil,
        &s.render_pass,
    )
    if result != vk.Result.SUCCESS {
        log.error("Failed to crete render pass")
    }
}

@(private = "file")
shadow_pass_create_pipeline :: proc(s: ^Shadow_Pass) {
    config := default_pipeline_config()
    config.renderpass = s.render_pass
    config.layout = s.pipeline.pipeline_layout
    config.descriptor_set_layout = s.pipeline.descriptor_layout

    // log.debugf("len(descriptor_sets): %v", len(pipeline.descriptor_sets))

    s.pipeline.shader = create_shader(
        s.pipeline.device,
        "bin/assets/shaders/Builtin.ShadowPass.spv",
    )
    // pipeline.shader.pipeline = &pipeline

    vert_stage_create_info := vk.PipelineShaderStageCreateInfo {
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.VERTEX},
        module = s.pipeline.shader.fragment_module,
        pName = "main",
    }

    frag_stage_create_info := vk.PipelineShaderStageCreateInfo {
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.FRAGMENT},
        module = s.pipeline.shader.fragment_module,
        pName = "main",
    }

    stages := []vk.PipelineShaderStageCreateInfo{vert_stage_create_info, frag_stage_create_info}

    binding_descriptions: []vk.VertexInputBindingDescription = {vertex_binding_description()}
    attribute_descriptions := vertex_attribute_descriptions()

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
    rasterizer_create_info.depthBiasEnable = false
    rasterizer_create_info.depthBiasConstantFactor = 8
    rasterizer_create_info.depthBiasClamp = 0
    rasterizer_create_info.depthBiasSlopeFactor = 4
    rasterizer_create_info.frontFace = .COUNTER_CLOCKWISE

    multisampling_create_info := config.multisample_info
    // multisampling_create_info.rasterizationSamples = device_get_max_usable_sample_count(s.pipeline.device)
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
        depthTestEnable       = true,
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
        s.pipeline.device.device,
        0,
        1,
        &pipeline_create_info,
        nil,
        &s.pipeline.handle,
    ))
    s.pipeline.config = config
    return
}
