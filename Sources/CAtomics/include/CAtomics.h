// C11 atomics for Swift on macOS 14 (Swift's Synchronization.Atomic needs macOS 15).
// Header-only: every function is static inline.
#pragma once
#include <stdatomic.h>
#include <stdint.h>

static inline int64_t ah_load_acquire(const int64_t *p) {
    return atomic_load_explicit((const _Atomic int64_t *)p, memory_order_acquire);
}
static inline int64_t ah_load_relaxed(const int64_t *p) {
    return atomic_load_explicit((const _Atomic int64_t *)p, memory_order_relaxed);
}
static inline void ah_store_release(int64_t *p, int64_t v) {
    atomic_store_explicit((_Atomic int64_t *)p, v, memory_order_release);
}
static inline void ah_store_relaxed(int64_t *p, int64_t v) {
    atomic_store_explicit((_Atomic int64_t *)p, v, memory_order_relaxed);
}
static inline int64_t ah_fetch_add_relaxed(int64_t *p, int64_t v) {
    return atomic_fetch_add_explicit((_Atomic int64_t *)p, v, memory_order_relaxed);
}
