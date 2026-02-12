/*
 * hashset.h — Open-addressing hash set for page-aligned uint64_t addresses
 *
 * Thread safety: insert (0 → non-0) and contains use atomic ops,
 * so one writer + one reader can operate concurrently without a mutex.
 * Rehash is NOT thread-safe — call only from the thread that inserts.
 */
#ifndef HASHSET_H
#define HASHSET_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define HASHSET_INIT_CAP 256
#define HASHSET_LOAD_FACTOR 75  /* percent */

/* Fibonacci hashing constant for 64-bit */
#define FIB_HASH 11400714819323198485ULL

struct hashset {
	uint64_t *slots;
	uint64_t cap;     /* always power of 2 */
	uint64_t count;
};

static inline int hashset_init(struct hashset *h, uint64_t cap)
{
	if (cap < HASHSET_INIT_CAP)
		cap = HASHSET_INIT_CAP;
	/* Round up to power of 2 */
	uint64_t v = cap - 1;
	v |= v >> 1; v |= v >> 2; v |= v >> 4;
	v |= v >> 8; v |= v >> 16; v |= v >> 32;
	cap = v + 1;

	h->slots = (uint64_t *)calloc(cap, sizeof(uint64_t));
	if (!h->slots)
		return -1;
	h->cap = cap;
	h->count = 0;
	return 0;
}

static inline void hashset_destroy(struct hashset *h)
{
	free(h->slots);
	h->slots = NULL;
	h->cap = 0;
	h->count = 0;
}

static inline uint64_t hashset_index(uint64_t addr, uint64_t cap)
{
	return ((addr >> 12) * FIB_HASH) & (cap - 1);
}

static inline int hashset_contains(const struct hashset *h, uint64_t addr)
{
	uint64_t mask = h->cap - 1;
	uint64_t idx = hashset_index(addr, h->cap);
	for (;;) {
		uint64_t slot = __atomic_load_n(&h->slots[idx], __ATOMIC_ACQUIRE);
		if (slot == 0)
			return 0;
		if (slot == addr)
			return 1;
		idx = (idx + 1) & mask;
	}
}

/* Internal: insert without rehash check (used during rehash) */
static inline void hashset_insert_raw(uint64_t *slots, uint64_t cap, uint64_t addr)
{
	uint64_t mask = cap - 1;
	uint64_t idx = hashset_index(addr, cap);
	for (;;) {
		uint64_t slot = slots[idx];
		if (slot == 0) {
			__atomic_store_n(&slots[idx], addr, __ATOMIC_RELEASE);
			return;
		}
		if (slot == addr)
			return;  /* duplicate */
		idx = (idx + 1) & mask;
	}
}

static inline int hashset_rehash(struct hashset *h)
{
	uint64_t new_cap = h->cap * 2;
	uint64_t *new_slots = (uint64_t *)calloc(new_cap, sizeof(uint64_t));
	if (!new_slots)
		return -1;
	for (uint64_t i = 0; i < h->cap; i++) {
		if (h->slots[i] != 0)
			hashset_insert_raw(new_slots, new_cap, h->slots[i]);
	}
	free(h->slots);
	h->slots = new_slots;
	h->cap = new_cap;
	return 0;
}

static inline int hashset_insert(struct hashset *h, uint64_t addr)
{
	if (addr == 0)
		return -1;  /* 0 is sentinel */
	if (h->count * 100 >= h->cap * HASHSET_LOAD_FACTOR) {
		if (hashset_rehash(h) < 0)
			return -1;
	}
	/* Check if already present */
	if (hashset_contains(h, addr))
		return 0;
	hashset_insert_raw(h->slots, h->cap, addr);
	h->count++;
	return 0;
}

#endif /* HASHSET_H */
