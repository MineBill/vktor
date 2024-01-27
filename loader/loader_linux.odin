package loader
import "core:sys/linux"
import inotify "packages:odin-inotify"
import "core:fmt"

monitor_thread :: proc (data: rawptr) -> rawptr {
    context = runtime.default_context()
    fd := (cast(^os.Handle)data)^
    for {
        events := inotify.read_events(fd)
        for event in events do if event.name == "app.so" {
            fmt.printf("Got event %v\n", event)
        }
    }
    return nil
}
