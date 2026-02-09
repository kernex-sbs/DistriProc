#define _GNU_SOURCE
#include <linux/userfaultfd.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdio.h>
#include <poll.h>
#include <pthread.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

static long page_size;

struct handler_args {
    int uffd;
};

static void *fault_handler_thread(void *arg) {
    struct handler_args *args = (struct handler_args *)arg;
    int uffd = args->uffd;
    static struct uffd_msg msg;
    ssize_t nread;
    struct uffdio_copy uffdio_copy;
    char *page = NULL;

    if (posix_memalign((void **)&page, page_size, page_size) != 0) {
        perror("posix_memalign");
        exit(1);
    }

    printf("Handler ready\n");

    for (;;) {
        struct pollfd pollfd;
        pollfd.fd = uffd;
        pollfd.events = POLLIN;

        int res = poll(&pollfd, 1, -1);
        if (res == -1) {
            perror("poll");
            exit(1);
        }

        nread = read(uffd, &msg, sizeof(msg));
        if (nread == 0) {
            printf("EOF on userfaultfd\n");
            break;
        }
        if (nread == -1) {
            perror("read");
            exit(1);
        }

        if (msg.event != UFFD_EVENT_PAGEFAULT) {
            fprintf(stderr, "Unexpected event on userfaultfd\n");
            exit(1);
        }

        printf("Fault on page: %p\n", (void *)msg.arg.pagefault.address);

        /* Service the fault by copying a zero-filled page */
        memset(page, 0, page_size);
        uffdio_copy.src = (unsigned long)page;
        uffdio_copy.dst = (unsigned long)msg.arg.pagefault.address & ~(page_size - 1);
        uffdio_copy.len = page_size;
        uffdio_copy.mode = 0;
        uffdio_copy.copy = 0;

        if (ioctl(uffd, UFFDIO_COPY, &uffdio_copy) == -1) {
            perror("ioctl-UFFDIO_COPY");
            exit(1);
        }

        printf("Page served: %p\n", (void *)uffdio_copy.dst);
    }

    return NULL;
}

int main(int argc, char *argv[]) {
    int uffd;
    long uffd_flags;
    struct uffdio_api uffdio_api;
    struct uffdio_register uffdio_register;
    pthread_t thr;
    struct handler_args args;
    char *addr;
    unsigned long len = 4096 * 10; // 10 pages

    page_size = sysconf(_SC_PAGE_SIZE);

    /* Create userfaultfd object */
    uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY);
    if (uffd == -1) {
        perror("syscall-userfaultfd");
        fprintf(stderr, "Try: sudo sysctl -w vm.unprivileged_userfaultfd=1\n");
        exit(1);
    }

    /* Enable API */
    uffdio_api.api = UFFD_API;
    uffdio_api.features = 0;
    if (ioctl(uffd, UFFDIO_API, &uffdio_api) == -1) {
        perror("ioctl-UFFDIO_API");
        exit(1);
    }

    /* Allocate memory */
    addr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (addr == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    printf("Mapped memory at: %p\n", addr);

    /* Register memory range with userfaultfd */
    uffdio_register.range.start = (unsigned long)addr;
    uffdio_register.range.len = len;
    uffdio_register.mode = UFFDIO_REGISTER_MODE_MISSING;
    if (ioctl(uffd, UFFDIO_REGISTER, &uffdio_register) == -1) {
        perror("ioctl-UFFDIO_REGISTER");
        exit(1);
    }

    /* Spawn handler thread */
    args.uffd = uffd;
    if (pthread_create(&thr, NULL, fault_handler_thread, &args) != 0) {
        perror("pthread_create");
        exit(1);
    }

    /* Trigger faults */
    for (int i = 0; i < 3; i++) {
        char *target = addr + i * page_size;
        printf("Accessing page %d at %p...\n", i, target);
        target[0] = 'A' + i;
        if (target[0] == 'A' + i) {
            printf("Write successful: %p\n", target);
        } else {
            printf("Write failed at %p\n", target);
        }
    }

    // Give handler some time to print
    sleep(1);

    return 0;
}
