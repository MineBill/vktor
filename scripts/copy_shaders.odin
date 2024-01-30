package copy_shaders

import "core:fmt"
import "core:os"
import "core:os/os2"

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln(len(os.args))
        fmt.eprintln("Incorrect usage. odin run -- <from> <to>")
        return
    }
    from := os.args[1]
    to := os.args[2]

    if !os2.exists(from) || !os2.exists(to) {
        fmt.eprintf("One of %v or %v, or both, do not exist.", from, to)
        return
    }

    fmt.printf("Will compile from %v to %v", from , to)
}
