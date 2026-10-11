#include <string.h>
#include <signal.h>
#include <pthread.h>
#include <fcntl.h>
#include "fs/sockrestart.h"
#include "fs/fd.h"
#include "fs/sock.h"
#include "kernel/task.h"
#include "util/list.h"
extern const struct fd_ops socket_fdops;

static lock_t sockrestart_lock = LOCK_INITIALIZER;
static struct list listen_fds = LIST_INITIALIZER(listen_fds);

void sockrestart_begin_listen(struct fd *sock, int backlog) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    // listen() may legally be called again on an already-listening socket to
    // change its backlog.  Adding the same node to listen_fds twice would
    // corrupt the list, so only register the socket once and refresh the
    // backlog instead.  This also mirrors list_remove_safe() in end_listen(),
    // which treats a NULL next/prev pair as "not registered".
    if (list_null(&sock->sockrestart.listen))
        list_add(&listen_fds, &sock->sockrestart.listen);
    sock->sockrestart.backlog = backlog;
    unlock(&sockrestart_lock);
}

void sockrestart_end_listen(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    list_remove_safe(&sock->sockrestart.listen);
    unlock(&sockrestart_lock);
}

static struct list listen_tasks = LIST_INITIALIZER(listen_tasks);

void sockrestart_begin_listen_wait(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    if (current->sockrestart.count == 0)
        list_add(&listen_tasks, &current->sockrestart.listen);
    current->sockrestart.count++;
    unlock(&sockrestart_lock);
}

void sockrestart_end_listen_wait(struct fd *sock) {
    if (sock->ops != &socket_fdops)
        return;
    lock(&sockrestart_lock);
    current->sockrestart.count--;
    if (current->sockrestart.count == 0)
        list_remove(&current->sockrestart.listen);
    unlock(&sockrestart_lock);
}

bool sockrestart_should_restart_listen_wait() {
    lock(&sockrestart_lock);
    bool punt = current->sockrestart.punt;
    current->sockrestart.punt = false;
    unlock(&sockrestart_lock);
    return punt;
}

struct saved_socket {
    struct fd *sock;
    int type;
    int proto;
    int backlog;
    int status_flags;
    int reuse_addr;
    union {
        char name[128];
        struct sockaddr name_addr;
    };
    socklen_t name_len;
    struct list saved;
};

static struct list saved_sockets = LIST_INITIALIZER(saved_sockets);

// A final fd_close can already be waiting to unregister under this lock. Never
// resurrect its zero reference count: that closer will still destroy the fd.
static struct fd *sockrestart_retain_open(struct fd *sock) {
    unsigned count = atomic_load(&sock->refcount);
    while (count != 0) {
        if (atomic_compare_exchange_weak(&sock->refcount, &count, count + 1))
            return sock;
    }
    return NULL;
}

// Releasing the final fd reference calls sock_close(), which unregisters the
// listener and takes sockrestart_lock. Drain releases only after unlocking.
static void sockrestart_release_saved(struct list *saved_list) {
    struct saved_socket *saved, *tmp;
    list_for_each_entry_safe(saved_list, saved, tmp, saved) {
        list_remove(&saved->saved);
        fd_close(saved->sock);
        free(saved);
    }
}

// these should only be called from the main thread, but it's easiest to just lock for the whole time

void sockrestart_on_suspend() {
    struct list release_sockets = LIST_INITIALIZER(release_sockets);
    lock(&sockrestart_lock);
    assert(list_empty(&saved_sockets));
    struct fd *sock;
    list_for_each_entry(&listen_fds, sock, sockrestart.listen) {
        struct saved_socket *saved = malloc(sizeof(struct saved_socket));
        if (saved == NULL)
            continue; // better than a crash
        saved->sock = sockrestart_retain_open(sock);
        if (saved->sock == NULL) {
            free(saved);
            continue;
        }
        saved->proto = sock->socket.protocol;
        saved->backlog = sock->sockrestart.backlog;
        saved->status_flags = fcntl(sock->real_fd, F_GETFL, 0);
        if (saved->status_flags < 0) {
            printk("sockrestart: F_GETFL for fd %d failed (%s); not saving\n",
                   sock->real_fd, strerror(errno));
            list_add(&release_sockets, &saved->saved);
            continue;
        }
        unsigned size = sizeof(saved->type);
        // iOS may already have torn the socket down by the time the app is
        // told it is going to the background, which makes these two calls fail.
        // Asserting on that used to take the whole process down on every
        // suspension; instead skip the socket, because a socket we cannot
        // describe now cannot be rebuilt later either, and the guest can
        // recover by restarting its server.
        if (getsockopt(sock->real_fd, SOL_SOCKET, SO_TYPE, &saved->type, &size) < 0 ||
            size != sizeof(saved->type)) {
            printk("sockrestart: SO_TYPE for fd %d failed (%s); not saving\n",
                   sock->real_fd, strerror(errno));
            list_add(&release_sockets, &saved->saved);
            continue;
        }
        size = sizeof(saved->reuse_addr);
        int reuse_result = getsockopt(sock->real_fd, SOL_SOCKET, SO_REUSEADDR, &saved->reuse_addr, &size);
        if (reuse_result < 0 ||
            size != sizeof(saved->reuse_addr)) {
            printk("sockrestart: SO_REUSEADDR for fd %d failed (%s); not saving\n",
                   sock->real_fd, reuse_result < 0 ? strerror(errno) : "unexpected value size");
            list_add(&release_sockets, &saved->saved);
            continue;
        }
        saved->name_len = sizeof(saved->name);
        if (getsockname(sock->real_fd, (struct sockaddr *) &saved->name, &saved->name_len) < 0) {
            printk("sockrestart: getsockname for fd %d failed (%s); not saving\n",
                   sock->real_fd, strerror(errno));
            list_add(&release_sockets, &saved->saved);
            continue;
        }
        list_add(&saved_sockets, &saved->saved);
    }
    unlock(&sockrestart_lock);
    sockrestart_release_saved(&release_sockets);
}

void sockrestart_on_resume() {
    struct list release_sockets = LIST_INITIALIZER(release_sockets);
    lock(&sockrestart_lock);
    struct saved_socket *saved, *tmp;
    list_for_each_entry_safe(&saved_sockets, saved, tmp, saved) {
        list_remove(&saved->saved);
        int new_sock = socket(saved->name_addr.sa_family, saved->type, saved->proto);
        if (new_sock < 0) {
            printk("restarting socket(%d, %d, %d) failed: %s\n",
                    saved->name_addr.sa_family, saved->type, saved->proto, strerror(errno));
            goto thank_u_next;
        }
        // dup2 replaces the open file description, including its status flags.
        // Event-loop listeners must stay nonblocking: an empty queue or stale
        // readiness event must return EAGAIN instead of stalling the guest.
        if (fcntl(new_sock, F_SETFL, saved->status_flags) < 0) {
            printk("restoring socket status flags failed: %s\n", strerror(errno));
            goto thank_u_next;
        }
        // A listener which has served connections can retain TIME_WAIT
        // endpoints after suspension. Preserve its original bind policy so
        // those endpoints do not prevent rebuilding the same listener port.
        if (setsockopt(new_sock, SOL_SOCKET, SO_REUSEADDR,
                       &saved->reuse_addr, sizeof(saved->reuse_addr)) < 0) {
            printk("restoring socket SO_REUSEADDR failed: %s\n", strerror(errno));
            goto thank_u_next;
        }
        if (bind(new_sock, (struct sockaddr *) &saved->name, saved->name_len) < 0) {
            printk("rebinding socket failed: %s\n", strerror(errno));
            goto thank_u_next;
        }
        // bind() alone leaves a passive socket unable to accept: the kernel
        // refuses every connection until listen() is called. The rebuild used to
        // skip this, so the guest's server came back "successfully" with a
        // socket that answered nothing, and the app paid a full harness restart
        // to recover. Restore the exact backlog the original listen() used.
        if (listen(new_sock, saved->backlog) < 0) {
            printk("re-listening on socket failed: %s\n", strerror(errno));
            goto thank_u_next;
        }
        if (dup2(new_sock, saved->sock->real_fd) < 0) {
            // A failed dup2 leaves the original descriptor intact. Report the
            // failed recovery so the foreground health probe can detect it;
            // never close or replace the guest's descriptor on this path.
            printk("replacing socket fd %d failed: %s\n",
                   saved->sock->real_fd, strerror(errno));
            goto thank_u_next;
        }
        // Normally these differ, but do not close the restored descriptor if
        // the original descriptor was already released and socket reused it.
        if (new_sock == saved->sock->real_fd)
            new_sock = -1;

thank_u_next:
        if (new_sock >= 0)
            close(new_sock);
        list_add(&release_sockets, &saved->saved);
    }
    struct task *task;
    list_for_each_entry(&listen_tasks, task, sockrestart.listen) {
        task->sockrestart.punt = true;
        pthread_kill(task->thread, SIGUSR1);
    }
    unlock(&sockrestart_lock);
    sockrestart_release_saved(&release_sockets);
}
