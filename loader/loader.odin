package loader

// === Loader Package ===
// The purpose of this package is to initialize the window and application.
// Then, during development, it monitors the shared library (which is the Application)
// and reloads it if neccessary.

import win "../window"
import "core:c/libc"
import "core:dynlib"
import "core:fmt"
import "core:io"
import "core:log"
import "core:os"
import "core:os/os2"
import "core:runtime"
import "core:strings"
import "core:sync"
import "core:sys/windows"
import "core:thread"
import "vendor:glfw"
import "core:time"
import "../monitor"
import imgui "packages:odin-imgui"
import imgui_glfw "packages:odin-imgui/imgui_impl_glfw"
import imgui_vulkan "packages:odin-imgui/imgui_impl_vulkan"

Symbol_Table :: struct {
    init:     #type proc(win: glfw.WindowHandle, imgui_ctx: ^imgui.Context) -> rawptr,
    update:   #type proc(memory: rawptr, delta: f64) -> bool,
    destroy:  #type proc(memory: rawptr),
    get_size: #type proc() -> int,
    reloaded: #type proc(memory: rawptr, imgui_ctx: ^imgui.Context),
    __handle: dynlib.Library,
}

load_symbols :: proc(table: ^Symbol_Table) {
    when ODIN_OS == .Windows {
        LIB_PATH :: "./bin/app-copy.dll"
        // Sleep this amount of milliseconds before copying the dll
        // to prevent issues where the dll is not unlocked immediately.
        SLEEP_MS :: 100
        did_unload := dynlib.unload_library(table.__handle)
        table.__handle = nil
        log.debugf(
            "Unloading app.dll was %s",
            did_unload ? "successful" : "unsuccessful",
        )

        windows.Sleep(SLEEP_MS)
        // libc.system("copy .\\bin\\app.dll .\\bin\\app-copy.dll")
        os2.copy_file(".\\bin\\app-copy.dll", ".\\bin\\app.dll")
    } else when ODIN_OS == .Linux {
        LIB_PATH :: "./bin/app.so"
    }
    count, ok := dynlib.initialize_symbols(table, LIB_PATH)
    if !ok {
        log.errorf("Failed to load any symbols from app.dll")
    } else {
        log.debugf("Loaded %v symbols from app.dll", count)
    }
}

main :: proc() {
    context.logger = log.create_console_logger(
        .Debug,
        opt = {.Level, .Terminal_Color},
    )

    symbols: Symbol_Table
    load_symbols(&symbols)

    library_monitor: monitor.Monitor
    monitor.init(&library_monitor, "bin", {
        "app.dll",
        "app.so",
    })
    thread.create_and_start_with_data(&library_monitor, monitor.thread_proc)

    win.initialize_windowing()
    window := win.create(640 * 2, 480 * 1.5, "Vulkan Window")

    // ImGui Initialization
    imgui.CHECKVERSION()
    imgui.CreateContext(nil)
    imgui_ctx := imgui.GetCurrentContext()

    io := imgui.GetIO()
    io.ConfigFlags += {.DockingEnable}
    // io.ConfigFlags += {.ViewportsEnable}

    style := imgui.GetStyle()
    imgui.StyleColorsDark(style)

    imgui_glfw.InitForVulkan(window.handle, false)

    mem := symbols.init(window.handle, imgui_ctx)

    start_time := time.now()
    main_loop: for !win.should_close(window) {
        // defer tracy.FrameMark()
        win.update(&window)

        if library_monitor.triggered {
            library_monitor.triggered = false

            log.info("Game reload requested. Reloading..")

            new_symbols: Symbol_Table
            // load_symbols(&new_symbols)
            // if new_symbols.get_size() != symbols.get_size() {
            //     symbols.destroy(mem)
            //     mem = new_symbols.init(window.handle)
            //     symbols = new_symbols
            // } else {
            //     symbols = new_symbols
            //     symbols.reloaded(mem)
            // }
            load_symbols(&symbols)
            symbols.reloaded(mem, imgui_ctx)
        }

        t := time.now()
        delta := time.duration_seconds(time.diff(start_time, t))
        start_time = t

        quit := symbols.update(mem, delta)
        if quit do break main_loop

        // TARGET :: 1.0 / 144.0
        // if delta < TARGET {
        //     sleep := time.Duration((TARGET - delta) * f64(time.Second))
        //     time.sleep(sleep)
        // }
    }

    symbols.destroy(mem)
}
