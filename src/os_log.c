// os_log identifies the binary by the address of __dso_handle. Zig's linker puts
// that symbol in __DATA instead of on the Mach-O header, so macOS drops the
// subsystem and category and the message can't be composed.
#define __dso_handle _mh_execute_header
#include <os/log.h>

void zandy_os_log_with_type(os_log_t log, os_log_type_t type, const char *message) {
    os_log_with_type(log, type, "%{public}s", message);
}
