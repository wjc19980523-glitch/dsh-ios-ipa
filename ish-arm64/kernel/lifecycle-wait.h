#ifndef KERNEL_LIFECYCLE_WAIT_H
#define KERNEL_LIFECYCLE_WAIT_H

#include <stdbool.h>

/* ARM64 waits whose kernel implementation performs no host file mutation.
 * The interrupt dispatcher reacquires admission before signal/exit cleanup. */
static inline bool dsh_lifecycle_arm64_is_pure_wait(unsigned syscall_number) {
    switch (syscall_number) {
        case 22: case 72: case 73: // epoll, pselect, ppoll
        case 95: case 98: case 101: case 115: case 133: case 137: case 260:
            return true; // waitid/futex/sleep/sigsuspend/sigtimedwait/wait4
        default: return false;
    }
}

#endif
