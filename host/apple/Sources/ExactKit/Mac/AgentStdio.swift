#if os(macOS)
import Foundation
import Darwin

public enum AgentStdio {
    // reserve the driver's pipe before modules can write to stdout, even JSON logs.
    public static let replies: FileHandle = {
        fflush(stdout)
        let fd = dup(STDOUT_FILENO)
        guard fd >= 0 else { fatalError("exact agent: cannot reserve stdout") }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(fd)
            fatalError("exact agent: cannot redirect module stdout")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }()
}
#endif
