package main

import vk "vendor:vulkan"
import "core:log"
import stb "vendor:stb/image"
import "core:os"
import "core:math"
import "core:mem"
import imgui_vulkan "packages:odin-imgui/imgui_impl_vulkan"
import vma "packages:odin-vma"

USING_IMGUI :: true

when USING_IMGUI {
    ImGui_Image :: struct {
        ds: vk.DescriptorSet,
    }
} else {
    ImGui_Image :: struct{}
}

Image :: struct {
    device:         ^Device,
    handle:         vk.Image,
    memory:         vk.DeviceMemory,
    width, height:  u32,
    format:         vk.Format,
    mip_levels:     u32,
    sampler:        vk.Sampler,
    layer_count:    u32,

    view:           vk.ImageView,

    extra:          ImGui_Image,
    allocation:     vma.Allocation,
}

image_load_from_file :: proc(device: ^Device, file_name: string, flags := vk.ImageCreateFlags{}) -> (image: Image) {
    data, ok := os.read_entire_file(file_name)
    if !ok {
        log.errorf("Failed to open '%v'", file_name)
        return
    }
    defer delete(data)

    x, y, channels: i32
    image_data := stb.load_from_memory(raw_data(data), i32(len(data)), &x, &y, &channels, 4)
    // assert(channels == 4, "Alpha channels MUST be included")
    
    size := x * y * 4

    mip_levels := cast(u32)math.floor(math.log2(cast(f32)max(x, y))) + 1
    log.debugf("Will generated %v mip levels for '%v'", mip_levels, file_name)

    staging := buffer_create(
        device,
        u32(size),
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT})
    defer buffer_destroy(&staging)

    buffer_copy_data(&staging, image_data[:size])

    image = image_create(
        device, 
        u32(x), u32(y),
        mip_levels,
        .R8G8B8A8_SRGB,
        .OPTIMAL,
        {.TRANSFER_DST, .TRANSFER_SRC, .SAMPLED},
        flags)
    image.layer_count = 1

    image_transition_layout(&image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
    buffer_copy_to_image(&staging, &image)
    // transition_image_layout(&image, .R8G8B8A8_SRGB, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

    image_generate_mipmaps(&image)
    return
}

image_load_from_memory :: proc(device: ^Device, data: []byte, flags := vk.ImageCreateFlags{}) -> (image: Image) {
    x, y, channels: i32
    image_data := stb.load_from_memory(raw_data(data), i32(len(data)), &x, &y, &channels, 4)
    // assert(channels == 4, "Alpha channels MUST be included")
    
    size := x * y * 4

    mip_levels := cast(u32)math.floor(math.log2(cast(f32)max(x, y))) + 1
    // log.debugf("Will generated %v mip levels for '%v'", mip_levels, file_name)

    staging := buffer_create(
        device,
        u32(size),
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT})
    defer buffer_destroy(&staging)

    buffer_copy_data(&staging, image_data[:size])

    image = image_create(
        device, 
        u32(x), u32(y),
        mip_levels,
        .R8G8B8A8_SRGB,
        .OPTIMAL,
        {.TRANSFER_DST, .TRANSFER_SRC, .SAMPLED},
        flags)
    image.layer_count = 1

    image_transition_layout(&image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
    buffer_copy_to_image(&staging, &image)
    // transition_image_layout(&image, .R8G8B8A8_SRGB, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

    image_generate_mipmaps(&image)
    return
}

cubemap_image_load_from_files :: proc(device: ^Device, file_names: [6]string) -> (image: Image) {
    texture_data: [6][^]byte

    last_width, last_height, channels: i32
    for file, i in file_names {
        data, ok := os.read_entire_file(file)
        if !ok {
            log.errorf("Failed to open '%v'", file)
            return
        }
        defer delete(data)

        texture_data[i] = stb.load_from_memory(raw_data(data), i32(len(data)), &last_width, &last_height, &channels, 4)
    }

    CHANNELS :: 4
    LAYERS :: 6
    layer_size := last_width * last_height * CHANNELS
    total_size := layer_size * LAYERS

    staging := buffer_create(
        device,
        u32(total_size),
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT})
    defer buffer_destroy(&staging)

    data: rawptr

    buffer_map(&staging, &data)
    for i in 0..<LAYERS {
        // buffer_copy_data(&staging, texture_data[i][:layer_size])
        mem.copy(
            rawptr(uintptr(data) + uintptr(i32(i) * layer_size)),
            texture_data[i],
            int(layer_size))
    }
    buffer_unmap(&staging)

    mip_levels := u32(1)
    image = image_create(
        device, 
        u32(last_width), u32(last_height),
        mip_levels,
        .R8G8B8A8_SRGB,
        .OPTIMAL,
        {.TRANSFER_DST, .TRANSFER_SRC, .SAMPLED},
        {.CUBE_COMPATIBLE}, layer_count = LAYERS)
    image.layer_count = LAYERS

    image_transition_layout(&image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
    buffer_copy_to_image(&staging, &image)

    image_generate_mipmaps(&image, LAYERS)

    return
}

image_create :: proc(
    device: ^Device,
    width, height: u32,
    mip_levels: u32,
    format: vk.Format,
    tiling: vk.ImageTiling,
    usage: vk.ImageUsageFlags,
    flags := vk.ImageCreateFlags{},
    layer_count: u32 = 1,
    samples: vk.SampleCountFlags = {._1},
) -> (image: Image) {
    image.device = device
    image.mip_levels = mip_levels
    image.format = format
    image.width  = width
    image.height = height
    image.layer_count = layer_count

    image_info := vk.ImageCreateInfo {
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        extent = vk.Extent3D {
            width,
            height,
            1,
        },
        mipLevels = mip_levels,
        arrayLayers = layer_count,
        format = format,
        tiling = tiling,
        initialLayout = .UNDEFINED,
        usage = usage,
        sharingMode = .EXCLUSIVE,
        samples = samples,
        flags = flags,
    }

    allocation_create_info := vma.AllocationCreateInfo {
        usage = .AUTO,
        flags = {.HOST_ACCESS_SEQUENTIAL_WRITE},
    }
    vma.CreateImage(g_app.allocator, &image_info, &allocation_create_info, &image.handle, &image.allocation, nil)

    // memory_requirements: vk.MemoryRequirements
    // vk.GetImageMemoryRequirements(device.device, image.handle, &memory_requirements)

    // alloc_info := vk.MemoryAllocateInfo {
    //     sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
    //     allocationSize = memory_requirements.size,
    //     memoryTypeIndex = device_find_memory_type(
    //         device,
    //         memory_requirements.memoryTypeBits,
    //         {.DEVICE_LOCAL}), // @Note: Should this be a parameter?
    // }

    // vk_check(vk.AllocateMemory(device.device, &alloc_info, nil, &image.memory))
    // vk_check(vk.BindImageMemory(device.device, image.handle, image.memory, 0))
    return
}

image_destroy :: proc(image: ^Image) {
    vk.DestroyImageView(image.device.device, image.view, nil)
    vk.DestroySampler(image.device.device, image.sampler, nil)
    // vk.FreeMemory(image.device.device, image.memory, nil)
    // vk.DestroyImage(image.device.device, image.handle, nil)
    vma.DestroyImage(g_app.allocator, image.handle, image.allocation)
}

image_map :: proc(image: ^Image, data: ^rawptr) {
    vma.MapMemory(g_app.allocator, image.allocation, data)
}

image_unmap :: proc(image: ^Image) {
    vma.UnmapMemory(g_app.allocator, image.allocation)
}

image_transition_layout :: proc(image: ^Image, old_layout, new_layout: vk.ImageLayout) {
    transition_image_layout(image.device, image.handle, image.mip_levels, image.layer_count, old_layout, new_layout)
}

image_set_lod_bias :: proc(image: ^Image, bias: f32) {
    image.sampler = image_sampler_create(image.device, image.mip_levels, bias)
}

transition_image_layout :: proc(device: ^Device, image: vk.Image, mip_levels: u32, layer_count: u32, old_layout, new_layout: vk.ImageLayout) {
    cmd := begin_single_time_command(device)
    defer end_single_time_command(device, cmd)

    barrier := vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = old_layout,
        newLayout = new_layout,

        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,

        image = image,
        subresourceRange = vk.ImageSubresourceRange {
            aspectMask = {.COLOR},
            baseMipLevel = 0,
            levelCount = mip_levels,
            baseArrayLayer = 0,
            layerCount = layer_count,
        },
    }

    source_stage, dest_stage: vk.PipelineStageFlags
    if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
        barrier.srcAccessMask = {}
        barrier.dstAccessMask = {.TRANSFER_WRITE}

        source_stage = {.TOP_OF_PIPE}
        dest_stage = {.TRANSFER}
    } else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
        barrier.srcAccessMask = {.TRANSFER_WRITE}
        barrier.dstAccessMask = {.SHADER_READ}

        source_stage = {.TRANSFER}
        dest_stage = {.FRAGMENT_SHADER}
    } else if old_layout == .UNDEFINED && new_layout == .SHADER_READ_ONLY_OPTIMAL {
        barrier.srcAccessMask = {.TRANSFER_READ}
        barrier.dstAccessMask = {.MEMORY_READ}

        source_stage = {.TRANSFER}
        dest_stage = {.TRANSFER}
    } else if old_layout == .PRESENT_SRC_KHR && new_layout == .TRANSFER_SRC_OPTIMAL {
        barrier.srcAccessMask = {.MEMORY_READ}
        barrier.dstAccessMask = {.TRANSFER_READ}

        source_stage = {.TRANSFER}
        dest_stage = {.TRANSFER}
    } else if old_layout == .TRANSFER_SRC_OPTIMAL && new_layout  == .PRESENT_SRC_KHR {
        barrier.srcAccessMask = {.TRANSFER_READ}
        barrier.dstAccessMask = {.MEMORY_READ}

        source_stage = {.TRANSFER}
        dest_stage = {.TRANSFER}
    } else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .GENERAL {
        barrier.srcAccessMask = {.TRANSFER_WRITE}
        barrier.dstAccessMask = {.MEMORY_READ}

        source_stage = {.TRANSFER}
        dest_stage = {.TRANSFER}
    } else if old_layout == .COLOR_ATTACHMENT_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
        barrier.srcAccessMask = {.COLOR_ATTACHMENT_WRITE}
        barrier.dstAccessMask = {.SHADER_READ}

        source_stage = {.COLOR_ATTACHMENT_OUTPUT}
        dest_stage = {.FRAGMENT_SHADER}
    } else if old_layout == .SHADER_READ_ONLY_OPTIMAL && new_layout == .COLOR_ATTACHMENT_OPTIMAL {
        barrier.srcAccessMask = {.SHADER_READ}
        barrier.dstAccessMask = {.COLOR_ATTACHMENT_WRITE}

        source_stage = {.FRAGMENT_SHADER}
        dest_stage = {.COLOR_ATTACHMENT_OUTPUT}
    }

    vk.CmdPipelineBarrier(
        cmd,
        source_stage, dest_stage,
        {},
        0, nil,
        0, nil,
        1, &barrier)
}

image_generate_mipmaps :: proc(image: ^Image, layer_count: u32 = 1) {
    cmd := begin_single_time_command(image.device)
    defer end_single_time_command(image.device, cmd)

    barrier := vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        image = image.handle,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        subresourceRange = vk.ImageSubresourceRange {
            aspectMask = {.COLOR},
            layerCount = 1,
            levelCount  = 1,
        },
    }

    for j in 0 ..< image.layer_count {
        barrier.subresourceRange.baseArrayLayer = j
        width  := i32(image.width)
        height := i32(image.height)
        for i in 1 ..< image.mip_levels {
            barrier.subresourceRange.baseMipLevel = i - 1
            barrier.oldLayout = .TRANSFER_DST_OPTIMAL
            barrier.newLayout = .TRANSFER_SRC_OPTIMAL
            barrier.srcAccessMask = {.TRANSFER_WRITE}
            barrier.dstAccessMask = {.TRANSFER_READ}

            vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)

            blit := vk.ImageBlit{
                srcOffsets = {
                    {0, 0, 0},
                    {width, height, 1},
                },
                dstOffsets = {
                    {0, 0, 0},
                    {width > 1 ? width / 2: 1, height > 1 ? height / 2: 1, 1},
                },
                srcSubresource = vk.ImageSubresourceLayers {
                    aspectMask = {.COLOR},
                    mipLevel = i - 1,
                    baseArrayLayer = j,
                    layerCount = 1,
                },
                dstSubresource = vk.ImageSubresourceLayers {
                    aspectMask = {.COLOR},
                    mipLevel = i,
                    baseArrayLayer = j,
                    layerCount = 1,
                },
            }

            vk.CmdBlitImage(
                cmd, 
                image.handle, .TRANSFER_SRC_OPTIMAL,
                image.handle, .TRANSFER_DST_OPTIMAL,
                1, &blit, .LINEAR)

            barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
            barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
            barrier.srcAccessMask = {.TRANSFER_READ}
            barrier.dstAccessMask = {.SHADER_READ}

            vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)
            if width > 1 do width /= 2
            if height > 1 do height /= 2
        }

        barrier.subresourceRange.baseMipLevel = image.mip_levels - 1
        barrier.oldLayout = .TRANSFER_DST_OPTIMAL
        barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
        barrier.srcAccessMask = {.TRANSFER_WRITE}
        barrier.dstAccessMask = {.SHADER_READ}

        vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)
    }

    image.sampler = image_sampler_create(image.device, image.mip_levels)
}

// Takes and returns custom wrappers over the vk objects.
image_view_create :: proc(image: ^Image, format: vk.Format, aspect: vk.ImageAspectFlags) {
    image.view = image_view_create_raw(
        image.device,
        image.handle,
        image.mip_levels,
        format,
        aspect, .D2)
    return
}

cubemap_image_view_create :: proc(image: ^Image, aspect: vk.ImageAspectFlags) {
    image.view = image_view_create_raw(
        image.device,
        image.handle,
        image.mip_levels,
        image.format,
        aspect, .CUBE, 6)
    return
}

// Takes and returns raw Vulkan objects.
image_view_create_raw :: proc(
    device: ^Device,
    image: vk.Image,
    mip_levels: u32,
    format: vk.Format,
    aspect: vk.ImageAspectFlags,
    view_type: vk.ImageViewType,
    layer_count: u32 = 1,
) -> (view: vk.ImageView) {
    view_info := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = image,
        viewType = view_type,
        format = format,
        subresourceRange = vk.ImageSubresourceRange {
            aspectMask = aspect,
            baseMipLevel = 0,
            levelCount = mip_levels,
            baseArrayLayer = 0,
            layerCount = layer_count,
        },
    }

    vk_check(vk.CreateImageView(device.device, &view_info, nil, &view))
    return
}

image_sampler_create :: proc(device: ^Device, mip_levels: u32 = 0, bias: f32 = 0) -> (sampler: vk.Sampler) {
    sampler_info := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        magFilter = .NEAREST,
        minFilter = .NEAREST,
        addressModeU = .REPEAT,
        addressModeV = .REPEAT,
        addressModeW = .REPEAT,
        anisotropyEnable = true,
        maxAnisotropy = device.properties.limits.maxSamplerAnisotropy,
        borderColor = .INT_OPAQUE_BLACK,
        unnormalizedCoordinates = false,
        compareEnable = false,
        compareOp = .ALWAYS,
        mipmapMode = .LINEAR,
        mipLodBias = bias,
        minLod = 0,
        maxLod = f32(mip_levels),
    }

    vk_check(vk.CreateSampler(device.device, &sampler_info, nil, &sampler))
    return
}

image_sampler_destroy :: proc(device: ^Device, sampler: vk.Sampler) {
    vk.DestroySampler(device.device, sampler, nil)
}
