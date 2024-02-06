package main

import vk "vendor:vulkan"
import "core:mem"
import vma "packages:odin-vma"
import "core:log"

Buffer :: struct {
    device: ^Device,
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    allocation: vma.Allocation,
}

Vertex_Buffer :: struct {
    // This is the buffer that lives in the GPU.
    vertex_buffer:  Buffer,
}

create_vertex_buffer :: proc(device: ^Device, vertices: []$T) -> (vb: Buffer) {
    size := u32(size_of(T) * len(vertices))
    staging_buffer := buffer_create(
        device,
        size,
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT})
    defer buffer_destroy(&staging_buffer)

    buffer_copy_data(&staging_buffer, vertices)

    vb = buffer_create(
        device,
        size,
        {.VERTEX_BUFFER, .TRANSFER_DST},
        {.DEVICE_LOCAL})

    buffer_copy(&staging_buffer, &vb, size)

    return
}

create_index_buffer :: proc(device: ^Device, indices: []$T) -> (buffer: Buffer) {
    size := u32(size_of(T) * len(indices))
    staging := buffer_create(
        device,
        size,
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT})
    defer buffer_destroy(&staging)

    buffer_copy_data(&staging, indices)

    buffer = buffer_create(
        device,
        size,
        {.TRANSFER_DST, .INDEX_BUFFER},
        {.DEVICE_LOCAL})

    buffer_copy(&staging, &buffer, size)
    return
}

destroy_vertex_buffer :: proc(buffer: ^Vertex_Buffer) {
    buffer_destroy(&buffer.vertex_buffer)
}

buffer_copy_vertices :: proc(buffer: ^Buffer, vertices: []Vertex) {
    size := vk.DeviceSize(size_of(Vertex) * len(vertices))

    data: rawptr
    vma.MapMemory(g_app.allocator, buffer.allocation, &data)
    mem.copy(data, raw_data(vertices), int(size))
    vma.UnmapMemory(g_app.allocator, buffer.allocation)
}

buffer_copy_indices :: proc(buffer: ^Buffer, indices: []u32) {
    size := vk.DeviceSize(size_of(u32) * len(indices))

    data: rawptr
    vma.MapMemory(g_app.allocator, buffer.allocation, &data)
    mem.copy(data, raw_data(indices), int(size))
    vma.UnmapMemory(g_app.allocator, buffer.allocation)
}

buffer_copy_data :: proc(buffer: ^Buffer, slice: []$T) {
    size := vk.DeviceSize(size_of(T) * len(slice))

    data: rawptr
    vma.MapMemory(g_app.allocator, buffer.allocation, &data)
    mem.copy(data, raw_data(slice), int(size))
    vma.UnmapMemory(g_app.allocator, buffer.allocation)
}

// Should this take a device as well? Or is it ok to take one one
// from the buffers (which will probably be the same).
buffer_copy :: proc(source: ^Buffer, dest: ^Buffer, size: u32) {
    cmd := begin_single_time_command(source.device)
    defer end_single_time_command(source.device, cmd)

    copy_region := vk.BufferCopy {
        srcOffset = 0,
        dstOffset = 0,
        size = vk.DeviceSize(size),
    }
    vk.CmdCopyBuffer(cmd, source.handle, dest.handle, 1, &copy_region)
}

buffer_copy_to_image :: proc(source: ^Buffer, image: ^Image) {
    cmd := begin_single_time_command(source.device)
    defer end_single_time_command(source.device, cmd)

    region := vk.BufferImageCopy {
        bufferOffset = 0,
        bufferRowLength = 0,
        bufferImageHeight = 0,

        imageSubresource = vk.ImageSubresourceLayers {
            aspectMask = {.COLOR},
            mipLevel = 0,
            baseArrayLayer = 0,
            layerCount = image.layer_count,
        },

        imageOffset = {0, 0, 0},
        imageExtent = {
            image.width,
            image.height,
            1.0,
        },
    }

    vk.CmdCopyBufferToImage(cmd, source.handle, image.handle, .TRANSFER_DST_OPTIMAL, 1, &region)
}

buffer_map :: proc(buffer: ^Buffer, data: ^rawptr) {
    vma.MapMemory(g_app.allocator, buffer.allocation, data)
}

buffer_unmap :: proc(buffer: ^Buffer)  {
    vma.UnmapMemory(g_app.allocator, buffer.allocation)
}

buffer_create :: proc(
    device: ^Device,
    size: u32,
    usage: vk.BufferUsageFlags,
    mem_props: vk.MemoryPropertyFlags,
) -> (buffer: Buffer) {
    buffer.device = device
    buffer_info := vk.BufferCreateInfo {
        sType = vk.StructureType.BUFFER_CREATE_INFO,
        size = vk.DeviceSize(size),
        usage = usage,
        sharingMode = vk.SharingMode.EXCLUSIVE,
    }

    ainfo := vma.AllocationCreateInfo {
        usage = .AUTO,
        flags = {.HOST_ACCESS_SEQUENTIAL_WRITE},
    }
    vk_check(vma.CreateBuffer(g_app.allocator, &buffer_info, &ainfo, &buffer.handle, &buffer.allocation, nil))
    vma.SetAllocationName(g_app.allocator, buffer.allocation, "Buffer")

    // memory_requirements: vk.MemoryRequirements
    // vk.GetBufferMemoryRequirements(buffer.device.device, buffer.handle, &memory_requirements)

    // alloc_info := vk.MemoryAllocateInfo {
    //     sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
    //     allocationSize = memory_requirements.size,
    //     memoryTypeIndex = device_find_memory_type(
    //         buffer.device,
    //         memory_requirements.memoryTypeBits,
    //         mem_props),
    // }

    // vk_check(vk.AllocateMemory(buffer.device.device, &alloc_info, nil, &buffer.memory))

    // vk.BindBufferMemory(buffer.device.device, buffer.handle, buffer.memory, 0)
    return
}

buffer_destroy :: proc(buffer: ^Buffer) {
    info: vma.AllocationInfo
    vma.GetAllocationInfo(g_app.allocator, buffer.allocation, &info)
    if info.pMappedData != nil {
        buffer_unmap(buffer)
    }
    vma.DestroyBuffer(g_app.allocator, buffer.handle, buffer.allocation)
}
