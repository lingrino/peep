/* A fixed-size ring buffer for bytes. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define RING_CAPACITY 4096

struct ring {
    uint8_t data[RING_CAPACITY];
    size_t head;
    size_t tail;
    size_t count;
};

static inline size_t min_size(size_t a, size_t b) {
    return a < b ? a : b;
}

void ring_init(struct ring *r) {
    memset(r, 0, sizeof *r);
}

bool ring_empty(const struct ring *r) {
    return r->count == 0;
}

size_t ring_space(const struct ring *r) {
    return RING_CAPACITY - r->count;
}

size_t ring_write(struct ring *r, const uint8_t *src, size_t len) {
    size_t n = min_size(len, ring_space(r));
    for (size_t i = 0; i < n; i++) {
        r->data[r->tail] = src[i];
        r->tail = (r->tail + 1) % RING_CAPACITY;
    }
    r->count += n;
    return n;
}

size_t ring_read(struct ring *r, uint8_t *dst, size_t len) {
    size_t n = min_size(len, r->count);
    for (size_t i = 0; i < n; i++) {
        dst[i] = r->data[r->head];
        r->head = (r->head + 1) % RING_CAPACITY;
    }
    r->count -= n;
    return n;
}

int ring_peek(const struct ring *r) {
    if (ring_empty(r)) {
        return -1;
    }
    return r->data[r->head];
}

#ifdef RING_DEMO
#include <stdio.h>
int main(void) {
    struct ring r;
    ring_init(&r);
    const char *msg = "hello, ring\n";
    ring_write(&r, (const uint8_t *)msg, strlen(msg));
    printf("%zu bytes buffered, first = '%c'\n", r.count, ring_peek(&r));
    return 0;
}
#endif
