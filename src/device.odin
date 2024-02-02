package main
import "core:log"
import "core:runtime"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

REQUIRED_VULKAN_LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}
REQUIRED_DEVICE_EXTENSIONS :: []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

Device :: struct {
    instance:        vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    physical_device: vk.PhysicalDevice,
    window:          glfw.WindowHandle,
    command_pool:    vk.CommandPool,
    device:          vk.Device,
    surface:         vk.SurfaceKHR,
    graphics_queue:  vk.Queue,
    present_queue:   vk.Queue,
    properties:      vk.PhysicalDeviceProperties,

    msaa_samples:    vk.SampleCountFlags,
}

create_device :: proc(window: glfw.WindowHandle, dbg: ^Debug_Context) -> (device: Device) {
    device.window = window
    device.instance = create_vulkan_instance(dbg)
    device.debug_messenger = setup_debug_callback(device.instance, dbg)

    result := glfw.CreateWindowSurface(device.instance, window, nil, &device.surface)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create window surface")
    }

    pick_physical_device(&device)

    device.msaa_samples = device_get_max_usable_sample_count(&device)

    split_version :: proc(version: u32) -> (major, minor, patch: u32) {
        major = version >> 22 & 0x000000ff
        minor = version >> 12 & 0x000000ff
        patch = version & 0x000000ff
        return
        // return (major<<22) | (minor<<12) | (patch)
    }
    log.infof("Using GPU Device: %s", device.properties.deviceName)
    log.infof("\tAPI Version: %v.%v.%v", split_version(device.properties.apiVersion))
    log.infof("\tDriver Version: %v.%v.%v", split_version(device.properties.driverVersion))

    create_logical_device(&device)
    create_command_pool(&device)

    return
}

destroy_device :: proc(device: ^Device) {
    log.infof("Destrying command pool")
    vk.DestroyCommandPool(device.device, device.command_pool, nil)
    log.infof("Destrying device")
    vk.DestroyDevice(device.device, nil)

    when VALIDATION {
        destroy_debug_messenger(device.instance, device.debug_messenger)
    }

    vk.DestroySurfaceKHR(device.instance, device.surface, nil)
    vk.DestroyInstance(device.instance, nil)
}

device_create_descriptor_pool :: proc(
    device: ^Device,
    count: u32,
    sizes: []vk.DescriptorPoolSize,
    flags := vk.DescriptorPoolCreateFlags{},
) -> (pool: vk.DescriptorPool) {
    pool_info := vk.DescriptorPoolCreateInfo {
        sType         = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
        poolSizeCount = u32(len(sizes)),
        pPoolSizes    = raw_data(sizes),
        maxSets       = count,
        flags = flags,
    }

    vk_check(vk.CreateDescriptorPool(device.device, &pool_info, nil, &pool))
    return
}

device_destroy_descriptor_pool :: proc(device: ^Device, pool: vk.DescriptorPool) {
    vk.DestroyDescriptorPool(device.device, pool, nil)
}

device_allocate_descriptor_sets :: proc(
    device: ^Device,
    pool: vk.DescriptorPool,
    count: u32,
    layout: vk.DescriptorSetLayout,
) -> (
    set: []vk.DescriptorSet,
) {
    layouts := make([]vk.DescriptorSetLayout, count, context.temp_allocator)
    for &l in layouts {
        l = layout
    }

    alloc_info := vk.DescriptorSetAllocateInfo {
        sType              = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = pool,
        descriptorSetCount = count,
        pSetLayouts        = raw_data(layouts),
    }

    set = make([]vk.DescriptorSet, count)
    vk_check(vk.AllocateDescriptorSets(device.device, &alloc_info, raw_data(set)))
    return
}

create_vulkan_instance :: proc(dbg: ^Debug_Context) -> (instance: vk.Instance) {
    when VALIDATION {
        if !check_validation_layers() {
            panic("Validation layer check failed. Cannot continue")
        }
    }

    info := vk.ApplicationInfo {
        sType              = vk.StructureType.APPLICATION_INFO,
        pApplicationName   = "Hello Triangle",
        applicationVersion = vk.MAKE_VERSION(1, 0, 0),
        pEngineName        = "No Engine",
        engineVersion      = vk.MAKE_VERSION(1, 0, 0),
        apiVersion         = vk.API_VERSION_1_3,
    }

    extensions := get_required_extensions()
    defer delete(extensions)

    instance_info := vk.InstanceCreateInfo {
        sType                   = vk.StructureType.INSTANCE_CREATE_INFO,
        pApplicationInfo        = &info,
        enabledExtensionCount   = cast(u32)len(extensions),
        ppEnabledExtensionNames = raw_data(extensions),
        enabledLayerCount       = 0,
    }

    when VALIDATION {
        layers := REQUIRED_VULKAN_LAYERS
        dbg_info := create_debug_info_struct(dbg)
        instance_info.enabledLayerCount = cast(u32)len(layers)
        instance_info.ppEnabledLayerNames = raw_data(layers)
        instance_info.pNext = cast(^vk.DebugUtilsMessengerCreateInfoEXT)(&dbg_info)
    }

    log.debug("Creating Vulkan instance")
    result := vk.CreateInstance(&instance_info, nil, &instance)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create Vulkan instance")
    }
    vk.load_proc_addresses_instance(instance)
    log.debug("Created Vulkan instance")

    return
}

create_semaphore :: proc(device: ^Device) -> (semaphore: vk.Semaphore) {
    semaphore_info := vk.SemaphoreCreateInfo {
        sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
    }

    vk_check(vk.CreateSemaphore(device.device, &semaphore_info, nil, &semaphore))
    return
}


destroy_semaphore :: proc(device: ^Device, semaphore: vk.Semaphore) {
    vk.DestroySemaphore(device.device, semaphore, nil)
}

create_semaphores :: proc(device: ^Device, count: u32) -> (semaphores: []vk.Semaphore) {
    semaphores = make([]vk.Semaphore, count)
    for i in 0 ..< count {
        semaphores[i] = create_semaphore(device)
    }
    return
}

destroy_semaphores :: proc(device: ^Device, semaphores: []vk.Semaphore) {
    for i in 0 ..< len(semaphores) {
        destroy_semaphore(device, semaphores[i])
    }
    delete(semaphores)
}

create_fence :: proc(device: ^Device, signaled: bool) -> (fence: vk.Fence) {
    fence_info := vk.FenceCreateInfo {
        sType = vk.StructureType.FENCE_CREATE_INFO,
    }

    if signaled {
        fence_info.flags += {.SIGNALED}
    }

    vk_check(vk.CreateFence(device.device, &fence_info, nil, &fence))
    return
}

destroy_fence :: proc(device: ^Device, fence: vk.Fence) {
    vk.DestroyFence(device.device, fence, nil)
}

create_fences :: proc(device: ^Device, count: u32) -> (fences: []vk.Fence) {
    fences = make([]vk.Fence, count)
    for i in 0 ..< count {
        fences[i] = create_fence(device, true)
    }
    return
}

destroy_fences :: proc(device: ^Device, fences: []vk.Fence) {
    for i in 0 ..< len(fences) {
        destroy_fence(device, fences[i])
    }
    delete(fences)
}

begin_single_time_command :: proc(device: ^Device) -> vk.CommandBuffer {
    cmd := create_command_buffer(device)

    begin_info := vk.CommandBufferBeginInfo {
        sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }

    vk.BeginCommandBuffer(cmd, &begin_info)
    return cmd
}

end_single_time_command :: proc(device: ^Device, cmd: vk.CommandBuffer) {
    cmd := cmd
    vk.EndCommandBuffer(cmd)

    submit_info := vk.SubmitInfo {
        sType              = vk.StructureType.SUBMIT_INFO,
        commandBufferCount = 1,
        pCommandBuffers    = &cmd,
    }
    vk.QueueSubmit(device.graphics_queue, 1, &submit_info, 0)
    vk.QueueWaitIdle(device.graphics_queue)

    destroy_command_buffer(device, cmd)
}

create_command_buffer :: proc(device: ^Device) -> (buffer: vk.CommandBuffer) {
    alloc_info := vk.CommandBufferAllocateInfo {
        sType              = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = device.command_pool,
        level              = .PRIMARY,
        commandBufferCount = 1,
    }

    vk_check(vk.AllocateCommandBuffers(device.device, &alloc_info, &buffer))
    return
}

destroy_command_buffer :: proc(device: ^Device, buffer: vk.CommandBuffer) {
    buffers: []vk.CommandBuffer = {buffer}
    vk.FreeCommandBuffers(device.device, device.command_pool, 1, raw_data(buffers))
}

create_command_buffers :: proc(device: ^Device, count: u32) -> (buffers: []vk.CommandBuffer) {
    buffers = make([]vk.CommandBuffer, count)
    alloc_info := vk.CommandBufferAllocateInfo {
        sType              = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = device.command_pool,
        level              = .PRIMARY,
        commandBufferCount = count,
    }

    vk_check(vk.AllocateCommandBuffers(device.device, &alloc_info, raw_data(buffers)))
    return
}

free_command_buffers :: proc(device: ^Device, buffers: []vk.CommandBuffer) {
    vk.FreeCommandBuffers(device.device, device.command_pool, u32(len(buffers)), raw_data(buffers))
    delete(buffers)
}

device_find_memory_type :: proc(
    device: ^Device,
    type_filter: u32,
    properties: vk.MemoryPropertyFlags,
) -> u32 {
    props: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(device.physical_device, &props)

    for i := u32(0); i < props.memoryTypeCount; i += 1 {
        type := props.memoryTypes[i]
        if (type_filter & u32(i << 1) != 0) && ((type.propertyFlags & properties) == properties) {
            return i
        }
    }

    panic("Failed to find suitable memory type")
}

check_validation_layers :: proc() -> bool {
    log.info("Performing validation layer check")
    count: u32
    vk.EnumerateInstanceLayerProperties(&count, nil)

    properties := make([]vk.LayerProperties, count, context.temp_allocator)
    vk.EnumerateInstanceLayerProperties(&count, raw_data(properties))

    req: for required_layer in REQUIRED_VULKAN_LAYERS {
        found := false
        for &property in properties {
            name := cstring(raw_data(&property.layerName))
            log.debugf("Checking layer %v", name)
            if required_layer == name {
                found = true
            }
        }
        if !found {
            log.errorf("Required validation layer '%s' not found!", required_layer)
            return false
        } else {
            log.debug("Found required validation layer:", required_layer)
            break req
        }
    }

    return true
}

pick_physical_device :: proc(device: ^Device) {
    count: u32
    vk.EnumeratePhysicalDevices(device.instance, &count, nil)

    devices := make([]vk.PhysicalDevice, count)
    defer delete(devices)

    vk.EnumeratePhysicalDevices(device.instance, &count, raw_data(devices))

    for dev in devices {
        if is_device_suitable(dev, device.surface) {
            device.physical_device = dev
            vk.GetPhysicalDeviceProperties(device.physical_device, &device.properties)
            return
        }
    }
    log.error("Failed to find a suitable GPU device")
    return
}

is_device_suitable :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> bool {
    indices := get_queue_families(device, surface)
    extensions_supported := check_device_extension_support(device)

    swapchain_good := false
    if extensions_supported {
        details := query_swapchain_support(device, surface)
        defer delete_swap_chain_support_details(&details)
        swapchain_good = len(details.formats) > 0 && len(details.present_modes) > 0
    }
    props: vk.PhysicalDeviceFeatures
    vk.GetPhysicalDeviceFeatures(device, &props)

    return(
        is_queue_family_complete(indices) &&
        extensions_supported &&
        swapchain_good &&
        props.samplerAnisotropy \
    )
}

Queue_Family_Indices :: struct {
    graphics_family: Maybe(int),
    present_family:  Maybe(int),
    compute_family:  Maybe(int),
}

is_queue_family_complete :: proc(using family: Queue_Family_Indices) -> bool {
    _, ok := family.graphics_family.?
    _, ok2 := family.present_family.?
    _, ok3 := family.compute_family.?
    return ok && ok2 && ok3
}

get_unique_queue_families :: proc(using indices: Queue_Family_Indices) -> [1]u32 {
    graphics, present, compute := cast(u32)graphics_family.(int), cast(u32)present_family.(int), cast(u32)compute_family.(int)
    if graphics == present {
        return {graphics}
    }
    log.error("Present and Graphics indices differe, do something")
    return {0}
}

get_queue_families :: proc(
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    indices: Queue_Family_Indices,
) {
    count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

    properties := make([]vk.QueueFamilyProperties, count)
    defer delete(properties)

    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(properties))

    for property, i in properties {
        if vk.QueueFlag.GRAPHICS in property.queueFlags {
            indices.graphics_family = i
        }

        if vk.QueueFlag.COMPUTE in property.queueFlags {
            indices.compute_family = i
        }

        present_support: b32 = false
        vk.GetPhysicalDeviceSurfaceSupportKHR(device, cast(u32)i, surface, &present_support)
        if present_support {
            indices.present_family = i
        }

        if (is_queue_family_complete(indices)) {
            break
        }
    }
    return
}

create_logical_device :: proc(device: ^Device) {
    indices := get_queue_families(device.physical_device, device.surface)

    unique_families := get_unique_queue_families(indices)
    queue_info := make(
        [dynamic]vk.DeviceQueueCreateInfo,
        0,
        len(unique_families),
        context.temp_allocator,
    )

    for fam in unique_families {
        queue_priority := []f32{1.0}
        append(
            &queue_info,
            vk.DeviceQueueCreateInfo {
                sType = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = fam,
                queueCount = 1,
                pQueuePriorities = raw_data(queue_priority),
            },
        )
    }

    device_features := vk.PhysicalDeviceFeatures {
        samplerAnisotropy = true,
        sampleRateShading = true,
    }

    create_info := vk.DeviceCreateInfo {
        sType                   = vk.StructureType.DEVICE_CREATE_INFO,
        pQueueCreateInfos       = raw_data(queue_info),
        queueCreateInfoCount    = cast(u32)len(queue_info),
        pEnabledFeatures        = &device_features,
        ppEnabledExtensionNames = raw_data(REQUIRED_DEVICE_EXTENSIONS),
        enabledExtensionCount   = cast(u32)len(REQUIRED_DEVICE_EXTENSIONS),
    }

    result := vk.CreateDevice(device.physical_device, &create_info, nil, &device.device)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create logical device")
        return
    }

    vk.GetDeviceQueue(
        device.device,
        cast(u32)indices.graphics_family.(int),
        0,
        &device.graphics_queue,
    )
    vk.GetDeviceQueue(
        device.device,
        cast(u32)indices.present_family.(int),
        0,
        &device.present_queue,
    )
    return
}

// Region: Helper procedures

// @Allocates
get_required_extensions :: proc() -> []cstring {
    extensions := make([dynamic]cstring)
    glfw_extensions := glfw.GetRequiredInstanceExtensions()
    for ext in glfw_extensions {
        append(&extensions, ext)
    }

    append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

    return extensions[:]
}

create_debug_info_struct :: proc(dbg: ^Debug_Context) -> vk.DebugUtilsMessengerCreateInfoEXT {
    return(
        vk.DebugUtilsMessengerCreateInfoEXT {
            sType = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = {.ERROR, .VERBOSE, .WARNING},
            messageType = {.DEVICE_ADDRESS_BINDING, .GENERAL, .PERFORMANCE, .VALIDATION},
            pfnUserCallback = debug_callback,
            pUserData = dbg,
        } \
    )
}

setup_debug_callback :: proc(
    instance: vk.Instance,
    dbg: ^Debug_Context,
) -> (
    debug_messenger: vk.DebugUtilsMessengerEXT,
) {
    info := create_debug_info_struct(dbg)

    func := cast(vk.ProcCreateDebugUtilsMessengerEXT)vk.GetInstanceProcAddr(
        instance,
        "vkCreateDebugUtilsMessengerEXT",
    )
    if func != nil {
        result := func(instance, &info, nil, &debug_messenger)
        if result != vk.Result.SUCCESS {
            log.errorf("Failed to create debug messenger: %v", result)
        }
    } else {
        log.error("Could not find proc 'vkDestroyDebugUtilsMessengerEXT'")
    }
    return
}

destroy_debug_messenger :: proc(instance: vk.Instance, messenger: vk.DebugUtilsMessengerEXT) {
    func := cast(vk.ProcDestroyDebugUtilsMessengerEXT)vk.GetInstanceProcAddr(
        instance,
        "vkDestroyDebugUtilsMessengerEXT",
    )
    if func != nil {
        func(instance, messenger, nil)
    } else {
        log.error("Could not find proc 'vkDestroyDebugUtilsMessengerEXT'")
    }
}

debug_callback :: proc "system" (
    messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
    messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData: rawptr,
) -> b32 {
    dbg := cast(^Debug_Context)pUserData
    context = runtime.default_context()
    context.logger = dbg.logger

    if strings.contains(string(pCallbackData.pMessage), "deviceCoherentMemory feature") do return false

    switch (messageSeverity) {
    case {.ERROR}:
        log.error(pCallbackData.pMessage)
    case {.VERBOSE}:
    // log.debug(pCallbackData.pMessage)
    case {.INFO}:
        log.info(pCallbackData.pMessage)
    case {.WARNING}:
        log.warn(pCallbackData.pMessage)
    }
    return false
}


Swap_Chain_Support_Details :: struct {
    capabilities:  vk.SurfaceCapabilitiesKHR,
    formats:       []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
}

delete_swap_chain_support_details :: proc(using details: ^Swap_Chain_Support_Details) {
    delete(formats)
    delete(present_modes)
}

query_swapchain_support :: proc(
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    details: Swap_Chain_Support_Details,
) {
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities)

    format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, nil)

    if format_count != 0 {
        details.formats = make([]vk.SurfaceFormatKHR, format_count)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(
            device,
            surface,
            &format_count,
            raw_data(details.formats),
        )
    }

    present_mode_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, nil)
    if present_mode_count != 0 {
        details.present_modes = make([]vk.PresentModeKHR, present_mode_count)
        vk.GetPhysicalDeviceSurfacePresentModesKHR(
            device,
            surface,
            &present_mode_count,
            raw_data(details.present_modes),
        )
    }
    return
}

create_command_pool :: proc(using d: ^Device) {
    indices := get_queue_families(physical_device, surface)
    pool_create_info := vk.CommandPoolCreateInfo {
        sType = vk.StructureType.COMMAND_POOL_CREATE_INFO,
        flags = {vk.CommandPoolCreateFlag.RESET_COMMAND_BUFFER},
        queueFamilyIndex = cast(u32)indices.graphics_family.(int),
    }

    result := vk.CreateCommandPool(device, &pool_create_info, nil, &command_pool)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create command pool")
    }
}

check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
    count: u32
    vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)

    properties := make([]vk.ExtensionProperties, count)
    defer delete(properties)
    vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(properties))

    req: for required_device_extension in REQUIRED_DEVICE_EXTENSIONS {
        found := false
        for &property in properties {
            if required_device_extension == cstring(raw_data(&property.extensionName)) {
                found = true
            }
        }
        if !found {
            log.errorf("Required device extention '%s' not found!", required_device_extension)
            return false
        } else {
            log.debug("Found required device extention: ", required_device_extension)
            break req
        }
    }

    return true
}

device_get_max_usable_sample_count :: proc(device: ^Device) -> (flags: vk.SampleCountFlags) {
    counts := device.properties.limits.framebufferColorSampleCounts & device.properties.limits.framebufferDepthSampleCounts
    if ._64 in counts {
        return {._64}
    }
    if ._32 in counts {
        return {._32}
    }
    if ._16 in counts {
        return {._16}
    }
    if ._8 in counts {
        return {._8}
    }
    if ._4 in counts {
        return {._4}
    }
    if ._2 in counts {
        return {._2}
    }

    return {._1}
}
