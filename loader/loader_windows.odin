package loader
import "core:fmt"
import "core:runtime"
import "core:sys/windows"

monitor_thread :: proc(data: rawptr) {
    // handle := cast(^windows.HANDLE)data
    data := cast(^Thread_Data)data
    handle := cast(^windows.HANDLE)data.handle
    for {
        wait_status := windows.WaitForSingleObject(handle^, windows.INFINITE)
        switch wait_status {
        case windows.WAIT_OBJECT_0:
            buffer: [1024]byte
            bytes_returned: u32
            windows.ReadDirectoryChangesW(
                handle^,
                &buffer,
                u32(len(buffer)),
                false,
                windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
                &bytes_returned,
                nil,
                nil,
            )

            file_info := cast(^windows.FILE_NOTIFY_INFORMATION)&buffer

            name, _ := windows.wstring_to_utf8(
                &file_info.file_name[0],
                cast(int)file_info.file_name_length,
            )
            if name == "app.dll" {
                data.should_reload = true
            }

            windows.FindNextChangeNotification(handle^)
        case windows.WAIT_TIMEOUT:
            // Does this need to be handled?
            unreachable()
        }
    }
}
