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

Symbol_Table :: struct {
    init:     #type proc(win: ^win.Window) -> rawptr,
    update:   #type proc(memory: rawptr) -> bool,
    destroy:  #type proc(memory: rawptr),
    get_size: #type proc() -> int,
    reloaded: #type proc(memory: rawptr),
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

Thread_Data :: struct {
    handle:        rawptr,
    should_reload: bool,
}

main :: proc() {
    context.logger = log.create_console_logger(
        .Debug,
        opt = {.Level, .Terminal_Color},
    )

    symbols: Symbol_Table
    load_symbols(&symbols)

    data := Thread_Data{}

    when ODIN_OS == .Linux {
        fd := inotify.init()

        // We watch the bin folder instead of the library file itself because once
        // the compiler deletes it, the underlying inode will be invalidated.
        handle, _ := inotify.add_watch(
            fd,
            "/home/minebill/source/VulkanTest/bin/",
            {.Create},
        )
        defer inotify.rm_watch(fd, handle)

        data.handle = &handle
        thread.create_and_start_with_data(&data, monitor_thread)
    } else when ODIN_OS == .Windows {
        handle := windows.FindFirstChangeNotificationW(
            windows.utf8_to_wstring("bin"),
            false,
            windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
        )
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
            log.info("Game reload requested. Reloading..")
            load_symbols(&symbols)
            symbols.reloaded(mem)
        }

        quit := symbols.update(mem)
        if quit do break main_loop
    }

    symbols.destroy(mem)
}
