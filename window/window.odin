package window
import "vendor:glfw"
import "core:log"
import vk "vendor:vulkan"
import "core:c"
import "core:strings"

Window :: struct {
    handle:        glfw.WindowHandle,
    width, height: int,
    title:         string,
    event_context: Event_Context,
}

initialize_windowing :: proc() {
    log.info("Initializing application")
    if glfw.Init() != true {
        description, code := glfw.GetError()
        log.errorf("Failed to initialize GLFW:\n\tDescription: %s\n\tCode: %d", description, code)
        return
    }
    if !glfw.VulkanSupported() {
        log.error("VULKAN NOT SUPPORTED ON THIS DEVICE, LOADERS NOT FOUND")
    }
}

create :: proc(width, height: int, title: cstring) -> (window: Window) {
    window.width = width
    window.height = height
    window.title = strings.clone_from_cstring(title)

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    glfw.WindowHint(glfw.RESIZABLE, 1)
    window.handle = glfw.CreateWindow(cast(c.int)width, cast(c.int)height, title, nil, nil)
    return
}

destroy :: proc(window: ^Window) {
    delete(window.title)
}

should_close :: proc(window: Window) -> bool {
    return cast(bool)glfw.WindowShouldClose(window.handle)
}

update :: proc(window: ^Window) {
    clear(&window.event_context.events)
    flush_input()
    glfw.PollEvents()
}

get_extent :: proc(window: ^Window) -> vk.Extent2D {
    return {cast(u32)window.width, cast(u32)window.height}
}

next_event :: proc(window: ^Window, event: ^Event) -> bool {
    if len(window.event_context.events) == 0 {
        return false
    }

    event^ = pop(&window.event_context.events)

    return true
}

create_vulkan_surface :: proc(instance: vk.Instance, window: Window) -> (surface: vk.SurfaceKHR) {
    assert(window.handle != nil)
    result := glfw.CreateWindowSurface(instance, window.handle, nil, &surface)
    if result != vk.Result.SUCCESS {
        log.error("Failed to create window surface")
    }
    return
}

get_proc_address :: proc "c" () -> #type proc "c" (_: vk.Instance, _: cstring) -> rawptr {
    return glfw.GetInstanceProcAddress
}
