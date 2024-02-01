package main
import vk "vendor:vulkan"
import "core:log"

Cubemap_Side :: enum {
    Front,
    Back,
    Up,
    Down,
    Right,
    Left,
}

Cubemap_Pipeline :: struct {
    using pipeline:     Pipeline,
    swapchain:          ^Swapchain,

    pipeline_layout:    vk.PipelineLayout,
    descriptor_sets:    []vk.DescriptorSet,
    descriptor_layout:  vk.DescriptorSetLayout,
    descriptor_pool:    vk.DescriptorPool,

    uniform_buffers:        []Buffer,
    uniform_mapped_buffers: []rawptr,

    buffer:             Buffer,
    vertex_count:       u32,
    // images:             [Cubemap_Side]Image,
    // image_views:        [Cubemap_Side]Image_View,
    image:              Image,
}

cubemap_init :: proc(pipeline: ^Cubemap_Pipeline, device: ^Device, swapchain: ^Swapchain) {
    pipeline.device = device
    pipeline.swapchain = swapchain

    pipeline.descriptor_layout = create_cubemap_pipeline_descriptor_set_layout(pipeline.device)

    pipeline.descriptor_pool = device_create_descriptor_pool(pipeline.device, MAX_FRAMES_IN_FLIGHT, {
        {type = vk.DescriptorType.UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
        {type = vk.DescriptorType.COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
    })

    pipeline.descriptor_sets = device_allocate_descriptor_sets(
        pipeline.device,
        pipeline.descriptor_pool,
        MAX_FRAMES_IN_FLIGHT,
        pipeline.descriptor_layout,
    )
    crete_cubemap_pipeline_layout(pipeline)
    create_cubemap_pipeline(pipeline)

    file_names := [6]string {
        "assets/textures/skybox/right.jpg",
        "assets/textures/skybox/left.jpg",
        "assets/textures/skybox/top.jpg",
        "assets/textures/skybox/bottom.jpg",
        "assets/textures/skybox/front.jpg",
        "assets/textures/skybox/back.jpg",
    }

    pipeline.image = cubemap_image_load_from_files(device, file_names)
    cubemap_image_view_create(&pipeline.image, {.COLOR})

    log.debugf("%v", pipeline.image.sampler)

    // pipeline.images[.Front] = image_load_from_file(device, "assets/textures/skybox/front.jpg", {.CUBE_COMPATIBLE})
    // // pipeline.image_views[.Front] = image_view_create(&pipeline.images[.Front], .R8G8B8A8_SRGB, {.COLOR})

    // pipeline.images[.Back] = image_load_from_file(device, "assets/textures/skybox/back.jpg", {.CUBE_COMPATIBLE})
    // // pipeline.image_views[.Back] = image_view_create(&pipeline.images[.Back], .R8G8B8A8_SRGB, {.COLOR})

    // pipeline.images[.Up] = image_load_from_file(device, "assets/textures/skybox/top.jpg", {.CUBE_COMPATIBLE})
    // // pipeline.image_views[.Up] = image_view_create(&pipeline.images[.Up], .R8G8B8A8_SRGB, {.COLOR})

    // pipeline.images[.Down] = image_load_from_file(device, "assets/textures/skybox/bottom.jpg", {.CUBE_COMPATIBLE})
    // // pipeline.image_views[.Down] = image_view_create(&pipeline.images[.Down], .R8G8B8A8_SRGB, {.COLOR})

    // pipeline.images[.Right] = image_load_from_file(device, "assets/textures/skybox/right.jpg", {.CUBE_COMPATIBLE})
    // // pipeline.image_views[.right] = image_view_create(&pipeline.images[.right], .r8g8b8a8_srgb, {.color})

    // pipeline.images[.Left] = image_load_from_file(device, "assets/textures/skybox/left.jpg", {.CUBE_COMPATIBLE})
    // // pipeline.image_views[.Left] = image_view_create(&pipeline.images[.Left], .R8G8B8A8_SRGB, {.COLOR})

    vertices := []Simple_Vertext{
        {{-1.0,  1.0, -1.0,}},
        {{-1.0, -1.0, -1.0,}},
        {{ 1.0, -1.0, -1.0,}},
        {{ 1.0, -1.0, -1.0,}},
        {{ 1.0,  1.0, -1.0,}},
        {{-1.0,  1.0, -1.0,}},
        {{-1.0, -1.0,  1.0,}},
        {{-1.0, -1.0, -1.0,}},
        {{-1.0,  1.0, -1.0,}},
        {{-1.0,  1.0, -1.0,}},
        {{-1.0,  1.0,  1.0,}},
        {{-1.0, -1.0,  1.0,}},
        {{ 1.0, -1.0, -1.0,}},
        {{ 1.0, -1.0,  1.0,}},
        {{ 1.0,  1.0,  1.0,}},
        {{ 1.0,  1.0,  1.0,}},
        {{ 1.0,  1.0, -1.0,}},
        {{ 1.0, -1.0, -1.0,}},
        {{-1.0, -1.0,  1.0,}},
        {{-1.0,  1.0,  1.0,}},
        {{ 1.0,  1.0,  1.0,}},
        {{ 1.0,  1.0,  1.0,}},
        {{ 1.0, -1.0,  1.0,}},
        {{-1.0, -1.0,  1.0,}},
        {{-1.0,  1.0, -1.0,}},
        {{ 1.0,  1.0, -1.0,}},
        {{ 1.0,  1.0,  1.0,}},
        {{ 1.0,  1.0,  1.0,}},
        {{-1.0,  1.0,  1.0,}},
        {{-1.0,  1.0, -1.0,}},
        {{-1.0, -1.0, -1.0,}},
        {{-1.0, -1.0,  1.0,}},
        {{ 1.0, -1.0, -1.0,}},
        {{ 1.0, -1.0, -1.0,}},
        {{-1.0, -1.0,  1.0,}},
        {{ 1.0, -1.0,  1.0,}},
    }

    pipeline.buffer = create_vertex_buffer(device, vertices)
    pipeline.vertex_count = u32(len(vertices))

    create_cubemap_uniform_buffers(pipeline)
}

cubemap_deinit :: proc(c: ^Cubemap_Pipeline) {
    buffer_destroy(&c.buffer)

    for &ub in c.uniform_buffers {
        buffer_destroy(&ub)
    }

    image_destroy(&c.image)

    device_destroy_descriptor_pool(c.device, c.descriptor_pool)

    vk.DestroyDescriptorSetLayout(c.device.device, c.descriptor_layout, nil)

    vk.DestroyPipelineLayout(c.device.device, c.pipeline_layout, nil)
    destroy_grphics_pipeline(c)
}

create_cubemap_uniform_buffers :: proc(pipeline: ^Cubemap_Pipeline) {
    pipeline.uniform_buffers = make([]Buffer, MAX_FRAMES_IN_FLIGHT)
    pipeline.uniform_mapped_buffers = make([]rawptr, MAX_FRAMES_IN_FLIGHT)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        size := u32(size_of(Uniform_Buffer_Object))
        pipeline.uniform_buffers[i] = buffer_create(
            pipeline.device,
            size,
            {.UNIFORM_BUFFER},
            {.HOST_VISIBLE, .HOST_COHERENT},
        )

        vk.MapMemory(
            pipeline.device.device,
            pipeline.uniform_buffers[i].memory,
            0,
            vk.DeviceSize(size),
            {},
            &pipeline.uniform_mapped_buffers[i],
        )

        buffer_info := vk.DescriptorBufferInfo {
            buffer = pipeline.uniform_buffers[i].handle,
            offset = 0,
            range  = size_of(Uniform_Buffer_Object),
        }

        image_info := vk.DescriptorImageInfo {
            imageLayout = .READ_ONLY_OPTIMAL,
            imageView   = pipeline.image.view,
            sampler     = pipeline.image.sampler,
        }

        descriptor_writes := []vk.WriteDescriptorSet {
             {
                sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                dstSet = pipeline.descriptor_sets[i],
                dstBinding = 0,
                dstArrayElement = 0,
                descriptorType = .UNIFORM_BUFFER,
                descriptorCount = 1,
                pBufferInfo = &buffer_info,
            },
             {
                sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
                dstSet = pipeline.descriptor_sets[i],
                dstBinding = 1,
                dstArrayElement = 0,
                descriptorType = .COMBINED_IMAGE_SAMPLER,
                descriptorCount = 1,
                pImageInfo = &image_info,
            },
        }

        vk.UpdateDescriptorSets(
            pipeline.device.device,
            u32(len(descriptor_writes)),
            raw_data(descriptor_writes),
            0,
            nil,
        )
    }
}

crete_cubemap_pipeline_layout :: proc(pipeline: ^Cubemap_Pipeline) {
    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
        sType                  = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 0,
        setLayoutCount         = 1,
        pSetLayouts            = &pipeline.descriptor_layout,
    }

    vk_check(vk.CreatePipelineLayout(pipeline.device.device, &pipeline_layout_create_info, nil, &pipeline.pipeline_layout))
}

create_cubemap_pipeline :: proc(pipeline: ^Cubemap_Pipeline) {
    config := default_pipeline_config()
    config.renderpass = pipeline.swapchain.renderpass
    config.layout = pipeline.pipeline_layout
    config.descriptor_set_layout = pipeline.descriptor_layout

    // log.debugf("len(descriptor_sets): %v", len(pipeline.descriptor_sets))

    pipeline.shader = create_shader(
        pipeline.device,
        "bin/assets/shaders/Builtin.Cubemap.spv",
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

    binding_descriptions: []vk.VertexInputBindingDescription = {simple_vertex_binding_description()}
    attribute_descriptions := simple_vertex_attribute_descriptions()

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

create_cubemap_pipeline_descriptor_set_layout :: proc(device: ^Device) -> (layout: vk.DescriptorSetLayout) {
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


Simple_Vertext :: struct {
    position: vec3,
}

simple_vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
    return {binding = 0, stride = size_of(Simple_Vertext), inputRate = vk.VertexInputRate.VERTEX}
}

simple_vertex_attribute_descriptions :: proc() -> [1]vk.VertexInputAttributeDescription {
    return(
         {
             {
                binding = 0,
                location = 0,
                format = vk.Format.R32G32B32_SFLOAT,
                offset = u32(offset_of(Simple_Vertext, position)),
            },
        } \
    )
}
