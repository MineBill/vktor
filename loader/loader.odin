package loader

// === Loader Package ===
// The purpose of this package is to initialize the window and application.
// Then, during development, it monitors the shared library (which is the Application)
// and reloads it if neccessary.

import "core:dynlib"
import "core:os"
import "core:fmt"
import "core:log"
import "vendor:glfw"
import "core:strings"
import win "../window"
import "core:runtime"
import "core:sys/windows"
import "core:thread"
import "core:c/libc"
import "core:sync"
import "core:io"

Symbol_Table :: struct {
    init:       #type proc(win: ^win.Window) -> rawptr,
    update:     #type proc(memory: rawptr) -> bool,
    destroy:    #type proc(memory: rawptr),
    get_size:   #type proc() -> int,
    reloaded:   #type proc(memory: rawptr),

    __handle: dynlib.Library,
}

reload_count := 0

copy_file :: proc(dst_path, src_path: string) {
    src, _ := os.open(src_path)
    defer os.close(src)

    info, _ := os.fstat(src, context.temp_allocator)
    defer os.file_info_delete(info, context.temp_allocator)

    mode := os.O_RDWR | os.O_CREATE | os.O_TRUNC
    dst, _ := os.open(dst_path, mode)
    defer os.close(dst)

    _, err := io.copy(io.to_writer(os.stream_from_handle(dst)), io.to_reader(os.stream_from_handle(src)))
    log.infof("error: %v", err)
}

load_symbols :: proc(table: ^Symbol_Table) {
    when ODIN_OS == .Windows {
        LIB_PATH :: "./bin/app-copy.dll"
        did_unload := dynlib.unload_library(table.__handle)
        table.__handle = nil
        log.debugf("Did unload: %v", did_unload)

        libc.system("copy .\\bin\\app.dll .\\bin\\app-copy.dll")
        // copy_file(".\\bin\\app-copy.dll", ".\\bin\\app.dll")
    } else when ODIN_OS == .Linux {
        LIB_PATH :: "./bin/app.so"
    }
    count, ok := dynlib.initialize_symbols(table, LIB_PATH)
    log.debugf("Loaded %v symbols", count)
}

Thread_Data :: struct {
    handle:         rawptr,
    should_reload:  bool,
}

main :: proc() {
    context.logger = log.create_console_logger()

    symbols: Symbol_Table
    load_symbols(&symbols)

    data := Thread_Data {}

    when ODIN_OS == .Linux {
        fd := inotify.init()

        // We watch the bin folder instead of the library file itself because once
        // the compiler deletes it, the underlying inode will be invalidated.
        handle, _ := inotify.add_watch(fd, "/home/minebill/source/VulkanTest/bin/", {.Create})
        defer inotify.rm_watch(fd, handle)

        data.handle = &handle
        thread.create_and_start_with_data(&data, monitor_thread)
    } else when ODIN_OS == .Windows {
        handle := windows.FindFirstChangeNotificationW(windows.utf8_to_wstring("bin"), false, windows.FILE_NOTIFY_CHANGE_LAST_WRITE)
        defer windows.FindCloseChangeNotification(handle)

        data.handle = &handle
        thread.create_and_start_with_data(&data, monitor_thread)
    }

    win.initialize_windowing()
    window := win.create(640, 480, "Vulkan Window")
    win.setup_events(&window)

    mem := symbols.init(&window)

    main_loop: for !win.should_close(window) {
        win.update(&window)

        if data.should_reload {
            data.should_reload = false
            log.info("Reloading!!")
            load_symbols(&symbols)
            symbols.reloaded(mem)
        }

        quit := symbols.update(mem)
        if quit do break main_loop
    }

    // symbols.destroy(mem)
}
