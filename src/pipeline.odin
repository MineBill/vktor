package main
import vk "vendor:vulkan"
import "core:log"

Pipeline :: struct {
    device:   ^Device,
    pipeline: vk.Pipeline,
}

Pipeline_Config_Info :: struct {
    layout:                     vk.PipelineLayout,
    descriptor_set_layout:      vk.DescriptorSetLayout,
    renderpass:                 vk.RenderPass,

    viewport:                   vk.Viewport,
    scissor:                    vk.Rect2D,
    input_assembly_info:        vk.PipelineInputAssemblyStateCreateInfo,
    rasterization_info:         vk.PipelineRasterizationStateCreateInfo,
    multisample_info:           vk.PipelineMultisampleStateCreateInfo,
    colorblend_attachment_info: vk.PipelineColorBlendAttachmentState,
    colorblend_info:            vk.PipelineColorBlendStateCreateInfo,
    depth_stencil_info:         vk.PipelineDepthStencilStateCreateInfo,
}

default_pipeline_config :: proc() -> (config: Pipeline_Config_Info) {
    using config
    input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo {
        sType                  = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology               = vk.PrimitiveTopology.TRIANGLE_LIST,
        primitiveRestartEnable = false,
    }

    // Rasterizer
    rasterization_info = vk.PipelineRasterizationStateCreateInfo {
        sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        depthBiasEnable = false,
        rasterizerDiscardEnable = false,
        polygonMode = vk.PolygonMode.FILL,
        lineWidth = 1,
        cullMode = {vk.CullModeFlag.BACK},
        frontFace = vk.FrontFace.COUNTER_CLOCKWISE,
        depthClampEnable = false,
    }

    multisample_info = vk.PipelineMultisampleStateCreateInfo {
        sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        sampleShadingEnable = false,
        rasterizationSamples = {vk.SampleCountFlag._1},
    }

    colorblend_attachment_info = vk.PipelineColorBlendAttachmentState {
        colorWriteMask = {
            vk.ColorComponentFlag.R,
            vk.ColorComponentFlag.G,
            vk.ColorComponentFlag.B,
            vk.ColorComponentFlag.A,
        },
        blendEnable = true,
        srcColorBlendFactor = vk.BlendFactor.SRC_ALPHA,
        dstColorBlendFactor = vk.BlendFactor.ONE_MINUS_SRC_ALPHA,
        colorBlendOp = vk.BlendOp.ADD,
        srcAlphaBlendFactor = vk.BlendFactor.ONE,
        dstAlphaBlendFactor = vk.BlendFactor.ZERO,
        alphaBlendOp = vk.BlendOp.ADD,
    }

    colorblend_info = vk.PipelineColorBlendStateCreateInfo {
        sType           = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable   = false,
        attachmentCount = 1,
        pAttachments    = nil,
    }
    return
}

create_graphics_pipeline :: proc(
    device: ^Device,
    config: Pipeline_Config_Info,
) -> (
    pipeline: Pipeline,
) {
    config := config
    pipeline.device = device
    vert_code := load_shader_from_file("bin/assets/shaders/Builtin.Object.vert.spv")
    frag_code := load_shader_from_file("bin/assets/shaders/Builtin.Object.frag.spv")
    defer {
        delete(vert_code)
        delete(frag_code)
    }
    if vert_code == nil || frag_code == nil {
        return
    }

    vert_module := create_shader_module(vert_code, device.device)
    frag_module := create_shader_module(frag_code, device.device)
    defer {
        vk.DestroyShaderModule(device.device, vert_module, nil)
        vk.DestroyShaderModule(device.device, frag_module, nil)
    }

    vert_stage_create_info := vk.PipelineShaderStageCreateInfo {
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.VERTEX},
        module = vert_module,
        pName = "main",
    }

    frag_stage_create_info := vk.PipelineShaderStageCreateInfo {
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.FRAGMENT},
        module = frag_module,
        pName = "main",
    }

    stages := []vk.PipelineShaderStageCreateInfo{vert_stage_create_info, frag_stage_create_info}

    binding_descriptions: []vk.VertexInputBindingDescription = {vertex_binding_description()}
    log.infof("%#v", raw_data(binding_descriptions))
    attribute_descriptions := vertex_attribute_descriptions()
    log.infof("%#v", raw_data(attribute_descriptions[:]))

    vertex_pipeline := vk.PipelineVertexInputStateCreateInfo {
        sType                           = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount   = u32(len(binding_descriptions)),
        pVertexBindingDescriptions = raw_data(binding_descriptions),
        vertexAttributeDescriptionCount = u32(len(attribute_descriptions)),
        pVertexAttributeDescriptions = raw_data(attribute_descriptions[:]),
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
        sType = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports = &viewport,
        scissorCount = 1,
        pScissors = &scissor,
    }

    depth_stencil_create_info := vk.PipelineDepthStencilStateCreateInfo {
        sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable = true,
        depthWriteEnable = true,
        depthCompareOp = .LESS,
        depthBoundsTestEnable = false,
        stencilTestEnable = false,
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

    result := vk.CreateGraphicsPipelines(
        device.device,
        0,
        1,
        &pipeline_create_info,
        nil,
        &pipeline.pipeline,
    )
    if result != vk.Result.SUCCESS {
        log.error("Failed to crete graphics pipeline")
    }
    return
}

destroy_grphics_pipeline :: proc(pipeline: ^Pipeline) {
    vk.DestroyPipeline(pipeline.device.device, pipeline.pipeline, nil)
}

pipeline_bind :: proc(pipeline: ^Pipeline, command_buffer: vk.CommandBuffer) {
    vk.CmdBindPipeline(command_buffer, vk.PipelineBindPoint.GRAPHICS, pipeline.pipeline)
}
