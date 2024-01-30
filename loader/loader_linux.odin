package loader
import "core:sys/linux"
import inotify "packages:odin-inotify"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:log"

Linux_Watcher :: struct {
    handle:        os.Handle,
    should_reload: bool,
}

init_watcher :: proc() -> (watcher: Linux_Watcher) {
    fd := inotify.init()

    // We watch the bin folder instead of the library file itself because once
    // the compiler deletes it, the underlying inode will be invalidated.
    handle, error := inotify.add_watch(
        fd,
        "/home/minebill/source/projects/vktor/bin",
        {.Create, .Delete},
    )
    log.errorf("Error while adding watch: %v", error)
    log.debugf("Handle is %v", fd)

    watcher.handle = fd
    return
}

deinit_watcher :: proc() {

}

watcher_thread :: proc (data: rawptr) {
    watcher := (cast(^Linux_Watcher)data)
    for {
        events := inotify.read_events(watcher.handle)
        for event in events {
            if strings.contains(event.name, "app.so") {
                watcher.should_reload = true
            }
        }
    }
}

watcher_should_reload :: proc(watcher: Linux_Watcher) -> bool {
    return watcher.should_reload
}

watcher_reset :: proc(watcher: ^Linux_Watcher) {
    watcher.should_reload = false
}
