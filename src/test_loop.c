#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#define HEAP_SIZE (1024 * 1024)  /* 1MB */
#define PATTERN_BYTE 0xAB

static volatile int running = 1;
static const char *output_file = NULL;

static void sigterm_handler(int sig) {
    (void)sig;
    running = 0;
}

static void write_counter(int counter) {
    if (!output_file)
        return;
    FILE *f = fopen(output_file, "w");
    if (f) {
        fprintf(f, "%d\n", counter);
        fclose(f);
    }
}

static int verify_heap(unsigned char *heap) {
    for (int i = 0; i < HEAP_SIZE; i++) {
        if (heap[i] != PATTERN_BYTE) {
            fprintf(stderr, "HEAP CORRUPTION at offset %d: expected 0x%02X got 0x%02X\n",
                    i, PATTERN_BYTE, heap[i]);
            return -1;
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    int counter = 0;

    /* Parse --output flag */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_file = argv[i + 1];
            i++;
        }
    }

    signal(SIGTERM, sigterm_handler);

    /* Allocate and fill heap with known pattern */
    unsigned char *heap = malloc(HEAP_SIZE);
    if (!heap) {
        perror("malloc");
        return 1;
    }
    memset(heap, PATTERN_BYTE, HEAP_SIZE);
    printf("Heap allocated: %d bytes at %p (pattern 0x%02X)\n",
           HEAP_SIZE, (void *)heap, PATTERN_BYTE);

    printf("PID: %d\n", getpid());
    printf("Looping... (Ctrl+C to stop)\n");
    fflush(stdout);

    while (running) {
        /* Verify heap integrity each iteration */
        if (verify_heap(heap) != 0) {
            fprintf(stderr, "Memory verification FAILED at counter=%d\n", counter);
            free(heap);
            return 1;
        }

        printf("Counter: %d [heap OK]\n", counter);
        fflush(stdout);
        write_counter(counter);
        counter++;
        sleep(1);
    }

    printf("Exiting at counter=%d\n", counter);
    if (verify_heap(heap) == 0) {
        printf("Final heap verification: OK\n");
    }
    free(heap);
    return 0;
}
