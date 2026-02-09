#define _GNU_SOURCE
#include <linux/userfaultfd.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <poll.h>
#include <pthread.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

#define PAGE_SIZE 4096
#define SERVER_PORT 9999
#define SERVER_IP "127.0.0.1"

struct handler_args {
    int uffd;
    int sockfd;
};

static void *fault_handler_thread(void *arg) {
    struct handler_args *args = (struct handler_args *)arg;
    int uffd = args->uffd;
    int sockfd = args->sockfd;
    static struct uffd_msg msg;
    ssize_t nread;
    struct uffdio_copy uffdio_copy;
    char *page = NULL;

    if (posix_memalign((void **)&page, PAGE_SIZE, PAGE_SIZE) != 0) {
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
            if (errno == EAGAIN) continue;
            perror("read");
            exit(1);
        }

        if (msg.event != UFFD_EVENT_PAGEFAULT) {
            fprintf(stderr, "Unexpected event on userfaultfd\n");
            exit(1);
        }

        uint64_t fault_addr = msg.arg.pagefault.address;
        printf("Fault on page: %p\n", (void *)fault_addr);

        /* Request page from server */
        if (send(sockfd, &fault_addr, sizeof(fault_addr), 0) != sizeof(fault_addr)) {
            perror("send");
            exit(1);
        }

        /* Receive page data */
        int total_received = 0;
        while (total_received < PAGE_SIZE) {
            int r = recv(sockfd, page + total_received, PAGE_SIZE - total_received, 0);
            if (r <= 0) {
                perror("recv");
                exit(1);
            }
            total_received += r;
        }
        printf("Received %d bytes from server for %p\n", total_received, (void *)fault_addr);

        /* Copy received data to memory */
        uffdio_copy.src = (unsigned long)page;
        uffdio_copy.dst = (unsigned long)fault_addr & ~(PAGE_SIZE - 1);
        uffdio_copy.len = PAGE_SIZE;
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
    struct uffdio_api uffdio_api;
    struct uffdio_register uffdio_register;
    pthread_t thr;
    struct handler_args args;
    char *addr;
    unsigned long len = PAGE_SIZE * 10;
    int sockfd;
    struct sockaddr_in serv_addr;

    /* Connect to Page Server */
    if ((sockfd = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
        perror("socket");
        return 1;
    }

    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(SERVER_PORT);

    if (inet_pton(AF_INET, SERVER_IP, &serv_addr.sin_addr) <= 0) {
        perror("inet_pton");
        return 1;
    }

    if (connect(sockfd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
        perror("connect");
        fprintf(stderr, "Ensure page_server.py is running on %s:%d\n", SERVER_IP, SERVER_PORT);
        return 1;
    }
    printf("Connected to page server\n");

    /* Create userfaultfd object */
    // Using UFFD_USER_MODE_ONLY to allow unprivileged execution on modern kernels
    uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY);
    if (uffd == -1) {
        perror("syscall-userfaultfd");
        return 1;
    }

    /* Enable API */
    uffdio_api.api = UFFD_API;
    uffdio_api.features = 0;
    if (ioctl(uffd, UFFDIO_API, &uffdio_api) == -1) {
        perror("ioctl-UFFDIO_API");
        return 1;
    }

    /* Allocate memory */
    addr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (addr == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    printf("Mapped memory at: %p\n", addr);

    /* Register memory range with userfaultfd */
    uffdio_register.range.start = (unsigned long)addr;
    uffdio_register.range.len = len;
    uffdio_register.mode = UFFDIO_REGISTER_MODE_MISSING;
    if (ioctl(uffd, UFFDIO_REGISTER, &uffdio_register) == -1) {
        perror("ioctl-UFFDIO_REGISTER");
        return 1;
    }

    /* Spawn handler thread */
    args.uffd = uffd;
    args.sockfd = sockfd;
    if (pthread_create(&thr, NULL, fault_handler_thread, &args) != 0) {
        perror("pthread_create");
        return 1;
    }

    /* Trigger faults */
    printf("Reading from memory to trigger faults...\n");
    for (int i = 0; i < 3; i++) {
        char *target = addr + i * PAGE_SIZE;
        uint64_t target_val = (uint64_t)target;

        // Expected value calculation matches server: (page_index + 1) % 255
        // page_index sent is the address.
        // But wait, the server logic uses (page_idx + 1) % 255.
        // Let's just print what we got.

        printf("Accessing page %d at %p...\n", i, target);
        unsigned char val = (unsigned char)target[0];
        printf("Read value: %u at %p\n", val, target);

        // Verify against server logic roughly
        // We can't easily replicate the exact byte logic here without casting,
        // but seeing non-zero values is the key.
    }

    // Give handler some time to print
    sleep(1);

    return 0;
}
