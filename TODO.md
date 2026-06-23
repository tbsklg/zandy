# TODO

- Replace `std.debug.print` in the child's sandbox-failure branch (main.zig) with an async-signal-safe write; `print` is not fork-safe, though it only runs on a cold error path before the child exits.
