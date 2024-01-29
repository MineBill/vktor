package main
import "core:log"
import "vendor:glfw"
import vk "vendor:vulkan"

Swapchain :: struct {
    swapchain_image_format:     vk.Format,
    extent:                     vk.Extent2D,
    framebuffers:               [dynamic]vk.Framebuffer,
    renderpass:                 vk.RenderPass,
    // depth_image_memories:       [dynamic]vk.DeviceMemory,
    // depth_images:               [dynamic]vk.Image,
    // depth_image_views:          [dynamic]vk.ImageView,
    depth_image:                Image,
    depth_image_view:           Image_View,
    swapchain_images:           [dynamic]vk.Image,
    swapchain_image_views:      [dynamic]vk.ImageView,
    device:                     ^Device,
    window_extent:              vk.Extent2D,
    swapchain_handle:           vk.SwapchainKHR,
    image_available_semaphores: []vk.Semaphore,
    render_finished_semaphores: []vk.Semaphore,
    in_flight_fences:           []vk.Fence,
    images_in_flight:           []vk.Fence,
    // image_available_semaphore:  vk.Semaphore,
    // render_finished_semaphore:  vk.Semaphore,
    // in_flight_fence:            vk.Fence,
    current_frame:              int,
}

create_swapchain :: proc(device: ^Device) -> (swapchain: Swapchain) {
    swapchain.device = device

    details := query_swapchain_support(device.physical_device, device.surface)
    defer delete_swap_chain_support_details(&details)

    present_mode := choose_swap_present_mode(details.present_modes)
    surface_format := choose_swap_surface_format(details.formats)
    swapchain.swapchain_image_format = surface_format.format
    swapchain.extent = choose_swap_extent(device, details.capabilities)

    image_count := details.capabilities.minImageCount + 1
    if details.capabilities.maxImageCount > 0 && image_count > details.capabilities.maxImageCount {
        image_count = details.capabilities.maxImageCount
    }

    create_info := vk.SwapchainCreateInfoKHR {
        sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
        surface = device.surface,
        minImageCount = image_count,
        imageFormat = swapchain.swapchain_image_format,
        imageColorSpace = surface_format.colorSpace,
        presentMode = present_mode,
        imageExtent = swapchain.extent,
        imageArrayLayers = 1,
        imageUsage = {vk.ImageUsageFlag.COLOR_ATTACHMENT},
        imageSharingMode = vk.SharingMode.EXCLUSIVE,
        preTransform = details.capabilities.currentTransform,
        compositeAlpha = {vk.CompositeAlphaFlagKHR.OPAQUE},
        clipped = true,
        oldSwapchain = 0,
    }

    result := vk.CreateSwapchainKHR(device.device, &create_info, nil, &swapchain.swapchain_handle)
    if result != vk.Result.SUCCESS {
        log.error("Failed to created swapchain")
    }

    swapchain_image_count: u32
    vk.GetSwapchainImagesKHR(
        device.device,
        swapchain.swapchain_handle,
        &swapchain_image_count,
        nil,
    )

    swapchain.swapchain_images = make([dynamic]vk.Image, swapchain_image_count)
    log.debug("Created", swapchain_image_count, "swapchain images")

    vk.GetSwapchainImagesKHR(
        device.device,
        swapchain.swapchain_handle,
        &swapchain_image_count,
        raw_data(swapchain.swapchain_images),
    )

    create_image_views(&swapchain)
    create_depth_resources(&swapchain)
    create_render_pass(&swapchain)
    create_framebuffers(&swapchain)
    create_sync_objects(&swapchain)
    return
}

destroy_swapchain :: proc(using swapchain: ^Swapchain) {
    for framebuffer in framebuffers {
        vk.DestroyFramebuffer(device.device, framebuffer, nil)
    }
    delete(framebuffers)

    for view in swapchain_image_views {
        vk.DestroyImageView(device.device, view, nil)
    }
    delete(swapchain_image_views)

    // TODO: Destroy depth stuff

    vk.DestroySwapchainKHR(device.device, swapchain_handle, nil)


    vk.DestroyRenderPass(device.device, renderpass, nil)

    destroy_semaphores(device, image_available_semaphores)
    destroy_semaphores(device, render_finished_semaphores)
    destroy_fences(device, in_flight_fences)
}

swapchain_acquire_next_image :: proc(swapchain: ^Swapchain) -> (index: u32, err: vk.Result) {
    vk.WaitForFences(
        swapchain.device.device,
        1,
        &swapchain.in_flight_fences[swapchain.current_frame],
        true,
        max(u64),
    )

    err = vk.AcquireNextImageKHR(
        swapchain.device.device,
        swapchain.swapchain_handle,
        max(u64),
        swapchain.image_available_semaphores[swapchain.current_frame],
        0,
        &index,
    )

    if err == .ERROR_OUT_OF_DATE_KHR || err == .SUBOPTIMAL_KHR {
        return {}, err
    } else if err != .SUCCESS {
        log.errorf("Failed to acquire next image: %v", err)
    }

    vk.ResetFences(
        swapchain.device.device,
        1,
        &swapchain.in_flight_fences[swapchain.current_frame],
    )
    return
}

swapchain_submit_command_buffers :: proc(swapchain: ^Swapchain, buffers: []vk.CommandBuffer) {
    wait_semaphores: []vk.Semaphore =  {
        swapchain.image_available_semaphores[swapchain.current_frame],
    }
    signal_semaphores: []vk.Semaphore =  {
        swapchain.render_finished_semaphores[swapchain.current_frame],
    }
    flags := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}

    submit_info := vk.SubmitInfo {
        sType                = vk.StructureType.SUBMIT_INFO,
        waitSemaphoreCount   = u32(len(wait_semaphores)),
        pWaitSemaphores      = raw_data(wait_semaphores),
        pWaitDstStageMask    = &flags,
        commandBufferCount   = u32(len(buffers)),
        pCommandBuffers      = raw_data(buffers),
        signalSemaphoreCount = u32(len(signal_semaphores)),
        pSignalSemaphores    = raw_data(signal_semaphores),
    }

    vk_check(
        vk.QueueSubmit(
            swapchain.device.graphics_queue,
            1,
            &submit_info,
            swapchain.in_flight_fences[swapchain.current_frame],
        ),
    )
}

swapchain_present :: proc(swapchain: ^Swapchain, image_index: u32) {
    image_index := image_index
    wait_semaphores: []vk.Semaphore =  {
        swapchain.image_available_semaphores[swapchain.current_frame],
    }
    signal_semaphores: []vk.Semaphore =  {
        swapchain.render_finished_semaphores[swapchain.current_frame],
    }

    swapchains: []vk.SwapchainKHR = {swapchain.swapchain_handle}

    present_info := vk.PresentInfoKHR {
        sType              = vk.StructureType.PRESENT_INFO_KHR,
        waitSemaphoreCount = u32(len(signal_semaphores)),
        pWaitSemaphores    = raw_data(signal_semaphores),
        swapchainCount     = u32(len(swapchains)),
        pSwapchains        = raw_data(swapchains),
        pImageIndices      = &image_index,
    }

    vk_check(vk.QueuePresentKHR(swapchain.device.present_queue, &present_info))
    swapchain.current_frame = (swapchain.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
}

choose_swap_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
    for format in formats {
        if format.format == vk.Format.B8G8R8A8_SRGB &&
           format.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
            return format
        }
    }
    log.warn(
        "Could not find ideal format and colorspace for swap surface, choosing: %v",
        formats[0],
    )
    return formats[0]
}

choose_swap_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
    for mode in modes {
        if mode == vk.PresentModeKHR.MAILBOX {
            return mode
        }
    }
    return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(
    device: ^Device,
    capabilities: vk.SurfaceCapabilitiesKHR,
) -> (
    extent: vk.Extent2D,
) {
    if capabilities.currentExtent.width != max(u32) {
        log.debug("Choosing swap extent: ", capabilities.currentExtent)
        return capabilities.currentExtent
    } else {
        width, height := glfw.GetFramebufferSize(device.window.handle)
        extent.width = clamp(
            cast(u32)width,
            capabilities.minImageExtent.width,
            capabilities.maxImageExtent.width,
        )
        extent.height = clamp(
            cast(u32)height,
            capabilities.minImageExtent.height,
            capabilities.maxImageExtent.height,
        )
    }
    return
}

create_image_views :: proc(using swapchain: ^Swapchain) {
    swapchain_image_views = make([dynamic]vk.ImageView, 0, len(swapchain.swapchain_images))

    for image in swapchain_images {
        // create_info := vk.ImageViewCreateInfo {
        //     sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
        //     format = swapchain_image_format,
        //     image = image,
        //     viewType = vk.ImageViewType.D2,
        //     components = vk.ComponentMapping {
        //         r = vk.ComponentSwizzle.IDENTITY,
        //         g = vk.ComponentSwizzle.IDENTITY,
        //         b = vk.ComponentSwizzle.IDENTITY,
        //         a = vk.ComponentSwizzle.IDENTITY,
        //     },
        //     subresourceRange = vk.ImageSubresourceRange {
        //         aspectMask = {vk.ImageAspectFlag.COLOR},
        //         baseMipLevel = 0,
        //         levelCount = 1,
        //         baseArrayLayer = 0,
        //         layerCount = 1,
        //     },
        // }

        // view: vk.ImageView
        // result := vk.CreateImageView(device.device, &create_info, nil, &view)
        // if result != vk.Result.SUCCESS {
        //     log.error("Failed to create image view:", result)
        //     // @Note: Maybe return here?
        //     continue
        // }

        view := image_view_create_raw(swapchain.device, image, 1, swapchain_image_format, {.COLOR})
        append(&swapchain_image_views, view)
    }
    log.debug("Created %v image views", len(swapchain_image_views))
}

create_render_pass :: proc(using swapchain: ^Swapchain) {
    attachment := vk.AttachmentDescription {
        format = swapchain_image_format,
        samples = {vk.SampleCountFlag._1},
        loadOp = vk.AttachmentLoadOp.CLEAR,
        storeOp = vk.AttachmentStoreOp.STORE,
        stencilLoadOp = vk.AttachmentLoadOp.DONT_CARE,
        stencilStoreOp = vk.AttachmentStoreOp.DONT_CARE,
        initialLayout = vk.ImageLayout.UNDEFINED,
        finalLayout = vk.ImageLayout.PRESENT_SRC_KHR,
    }

    attachment_ref := vk.AttachmentReference {
        attachment = 0,
        layout     = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
    }

    depth_attachment := vk.AttachmentDescription {
        format = swapchain.depth_image.format,
        samples = {._1},
        loadOp = .CLEAR,
        storeOp = .DONT_CARE,
        stencilLoadOp = .DONT_CARE,
        stencilStoreOp = .DONT_CARE,
        initialLayout = .UNDEFINED,
        finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    }

    depth_attachment_ref := vk.AttachmentReference {
        attachment = 1,
        layout     = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    }

    subpass := vk.SubpassDescription {
        pipelineBindPoint       = vk.PipelineBindPoint.GRAPHICS,
        colorAttachmentCount    = 1,
        pColorAttachments       = &attachment_ref,
        pDepthStencilAttachment = &depth_attachment_ref,
    }

    dependency := vk.SubpassDependency {
        srcSubpass = vk.SUBPASS_EXTERNAL,
        dstSubpass = 0,
        srcStageMask = {vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
        srcAccessMask = {},
        dstStageMask = {vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
        dstAccessMask = {vk.AccessFlag.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    }

    attachments := []vk.AttachmentDescription{attachment, depth_attachment}

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
        device.device,
        &render_pass_create_info,
        nil,
        &swapchain.renderpass,
    )
    if result != vk.Result.SUCCESS {
        log.error("Failed to crete render pass")
    }
}

create_depth_resources :: proc(swapchain: ^Swapchain) {
    extent := swapchain.extent
    format := find_supported_format(
        swapchain.device,
        {.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT},
        .OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT},
    )
    log.debugf("Selected depth format: %v", format)

    swapchain.depth_image = image_create(
        swapchain.device,
        extent.width,
        extent.height,
        1,
        format,
        .OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT},
    )
    swapchain.depth_image_view = image_view_create(&swapchain.depth_image, format, {.DEPTH})
}

find_supported_format :: proc(
    device: ^Device,
    candidates: []vk.Format,
    tiling: vk.ImageTiling,
    features: vk.FormatFeatureFlags,
) -> vk.Format {
    for format in candidates {
        props: vk.FormatProperties
        vk.GetPhysicalDeviceFormatProperties(device.physical_device, format, &props)
        if (tiling == .LINEAR && (props.linearTilingFeatures & features) == features) ||
           (tiling == .OPTIMAL && (props.optimalTilingFeatures & features) == features) {
            return format
        }
    }
    panic("Failed to find supported format")
}

create_framebuffers :: proc(using swapchain: ^Swapchain) {
    log.debugf("swapchain_image_views_len: %v ", len(swapchain_image_views))
    framebuffers = make(
        [dynamic]vk.Framebuffer,
        len(swapchain_image_views),
        len(swapchain_image_views),
    )

    for view, i in swapchain_image_views {
        attachments := []vk.ImageView{view, swapchain.depth_image_view.handle}

        framebuffer_create_info := vk.FramebufferCreateInfo {
            sType           = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
            renderPass      = renderpass,
            attachmentCount = u32(len(attachments)),
            pAttachments    = raw_data(attachments),
            width           = extent.width,
            height          = extent.height,
            layers          = 1,
        }

        result := vk.CreateFramebuffer(
            device.device,
            &framebuffer_create_info,
            nil,
            &framebuffers[i],
        )
        if result != vk.Result.SUCCESS {
            log.error("Failed to create framebuffer ", i)
        }
    }
    return
}

create_sync_objects :: proc(using swapchain: ^Swapchain) {
    image_available_semaphores = create_semaphores(device, MAX_FRAMES_IN_FLIGHT)
    render_finished_semaphores = create_semaphores(device, MAX_FRAMES_IN_FLIGHT)
    in_flight_fences = create_fences(device, MAX_FRAMES_IN_FLIGHT)
    return
}
