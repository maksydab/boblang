#if defined(__linux__)
  #define _GNU_SOURCE
#endif

#include "gc.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if defined(__linux__)
#include <malloc.h>
#endif

#if defined(_WIN32)
  #include <windows.h>
#elif !defined(__wasm__)
  #include <pthread.h>
  #include <unistd.h>
#endif

#define CHUNK_SIZE        (65536)
#define CHUNK_DATA_SIZE   (CHUNK_SIZE - 32)
#define GC_INTERVAL       (1048576)
#define HDR_SIZE          (16)
#define WORKLIST_INIT_CAP (4096)
#define WORKLIST_MAX_CAP  (16777216)

typedef struct AllocHdr {
    uint32_t magic;
    uint32_t size;
    uint32_t mark;
    uint32_t padding;
} AllocHdr;

static char* stack_top_hint = NULL;

void gc_set_stack_top(void* addr) {
    if (addr) stack_top_hint = addr;
}

typedef struct Chunk {
    struct Chunk* next;
    char* bump;
    char* data;
    char raw_data[CHUNK_DATA_SIZE];
} Chunk;

static GcDestructor global_dtor;
static GcTraceFn global_tracer;

static Chunk* active_chunk;
static Chunk* all_chunks;
static int alloc_count;
static int gc_running;

#if !defined(_WIN32) && !defined(__wasm__)
static pthread_mutex_t all_chunks_mutex;
static pthread_t sweep_thread;
static pthread_mutex_t sweep_mutex;
static pthread_cond_t sweep_cond;
static Chunk* sweep_queue;
static int sweep_pending;
static int shutdown_requested;

static Chunk* free_chunks;
static pthread_mutex_t free_mutex;
#else
static Chunk* free_chunks;
#endif

static void** worklist;
static int worklist_count;
static int worklist_cap;

static inline size_t align8(size_t n) {
    return (n + 7) & ~7;
}

static inline AllocHdr* get_hdr(void* ptr) {
    return (AllocHdr*)((char*)ptr - HDR_SIZE);
}

static inline void* get_ptr(AllocHdr* hdr) {
    return (char*)hdr + HDR_SIZE;
}

static Chunk* chunk_alloc(void) {
    Chunk* c = (Chunk*)malloc(sizeof(Chunk));
    if (!c) return NULL;
    c->next = NULL;
    c->data = (char*)(((uintptr_t)c->raw_data + 7) & ~(uintptr_t)7);
    c->bump = c->data;
    return c;
}

#if !defined(_WIN32) && !defined(__wasm__)
static int ptr_in_chunk(void* ptr, Chunk* c) {
    return (char*)ptr >= c->data && (char*)ptr < (c->data + CHUNK_DATA_SIZE);
}

static void*** gc_slots = NULL;
static int gc_slot_count = 0;
static int gc_slot_cap = 0;
static int* gc_frame_stack = NULL;
static int gc_frame_stack_cap = 0;
static int gc_frame_depth = 0;

void boblang_gc_frame_begin(void) {
    if (gc_frame_depth >= gc_frame_stack_cap) {
        gc_frame_stack_cap = gc_frame_stack_cap ? gc_frame_stack_cap * 2 : 64;
        gc_frame_stack = (int*)realloc(gc_frame_stack, gc_frame_stack_cap * sizeof(int));
    }
    gc_frame_stack[gc_frame_depth++] = gc_slot_count;
}

void boblang_gc_frame_end(void) {
    if (gc_frame_depth > 0) gc_slot_count = gc_frame_stack[--gc_frame_depth];
}

void boblang_gc_register_slot(void** slot) {
    if (gc_slot_count >= gc_slot_cap) {
        gc_slot_cap = gc_slot_cap ? gc_slot_cap * 2 : 64;
        gc_slots = (void***)realloc(gc_slots, gc_slot_cap * sizeof(void**));
    }
    gc_slots[gc_slot_count++] = slot;
}

static Chunk** sorted_chunk_list = NULL;
static int sorted_chunk_count = 0;
static int sorted_chunk_cap = 0;

static int cmp_chunk(const void* a, const void* b) {
    const Chunk* ca = *(Chunk* const*)a;
    const Chunk* cb = *(Chunk* const*)b;
    if (ca->data < cb->data) return -1;
    if (ca->data > cb->data) return 1;
    return 0;
}

static void rebuild_sorted_chunks(void) {
    pthread_mutex_lock(&all_chunks_mutex);
    int n = 0;
    for (Chunk* c = all_chunks; c; c = c->next) n++;
    if (n > sorted_chunk_cap) {
        sorted_chunk_list = (Chunk**)realloc(sorted_chunk_list, sizeof(Chunk*) * n);
        sorted_chunk_cap = n;
    }
    int i = 0;
    for (Chunk* c = all_chunks; c; c = c->next) sorted_chunk_list[i++] = c;
    sorted_chunk_count = n;
    qsort(sorted_chunk_list, sorted_chunk_count, sizeof(Chunk*), cmp_chunk);
    pthread_mutex_unlock(&all_chunks_mutex);
}

static int is_gc_ptr(void* ptr) {
    if (!ptr || ((uintptr_t)ptr & 7) != 0) return 0;
    int lo = 0, hi = sorted_chunk_count;
    while (lo < hi) {
        int mid = (lo + hi) >> 1;
        Chunk* c = sorted_chunk_list[mid];
        if ((char*)ptr < c->data) {
            hi = mid;
        } else if ((char*)ptr >= c->data + CHUNK_DATA_SIZE) {
            lo = mid + 1;
        } else {
            return 1;
        }
    }
    return 0;
}

static void mark_grey(void* ptr) {
    if (!is_gc_ptr(ptr)) return;
    AllocHdr* hdr = get_hdr(ptr);
    if (hdr->magic != GC_MAGIC) return;
    if (hdr->mark) return;
    hdr->mark = 1;

    if (worklist_count >= worklist_cap) {
        if (worklist_cap >= WORKLIST_MAX_CAP) return;
        int new_cap = worklist_cap ? worklist_cap * 2 : WORKLIST_INIT_CAP;
        if (new_cap > WORKLIST_MAX_CAP) new_cap = WORKLIST_MAX_CAP;
        void** wl = (void**)realloc(worklist, new_cap * sizeof(void*));
        if (!wl) return;
        worklist = wl;
        worklist_cap = new_cap;
    }
    worklist[worklist_count++] = ptr;
}

static void mark_roots(void) {
    for (int i = 0; i < gc_slot_count; i++) {
        if (gc_slots[i] && *gc_slots[i]) mark_grey(*gc_slots[i]);
    }
}

static void process_worklist(void) {
    int idx = 0;
    while (idx < worklist_count) {
        void* ptr = worklist[idx++];
        if (global_tracer)
            global_tracer(ptr, mark_grey);
    }
    worklist_count = 0;
}

static int sweep_chunk(Chunk* c) {
    char* p = c->data;
    int live = 0;

    while (p < c->bump) {
        AllocHdr* hdr = (AllocHdr*)p;
        if (hdr->magic != GC_MAGIC) {
            size_t hsz = hdr->size;
            if (!hsz) hsz = 8;
            p += align8(HDR_SIZE + hsz);
            continue;
        }
        size_t total = align8(HDR_SIZE + hdr->size);
        if (hdr->mark) {
            hdr->mark = 0;
            live = 1;
        } else {
            if (global_dtor) global_dtor(get_ptr(hdr));
            hdr->magic = 0;
        }
        p += total;
    }
    return live;
}

static void* sweep_worker(void* arg) {
    (void)arg;
    while (1) {
        pthread_mutex_lock(&sweep_mutex);
        while (!sweep_pending && !shutdown_requested)
            pthread_cond_wait(&sweep_cond, &sweep_mutex);
        if (shutdown_requested && !sweep_pending) {
            pthread_mutex_unlock(&sweep_mutex);
            return NULL;
        }
        Chunk* c = sweep_queue;
        sweep_queue = NULL;
        pthread_mutex_unlock(&sweep_mutex);

        while (c) {
            Chunk* next = c->next;
            c->next = NULL;
            if (sweep_chunk(c)) {
                pthread_mutex_lock(&all_chunks_mutex);
                c->next = all_chunks;
                all_chunks = c;
                pthread_mutex_unlock(&all_chunks_mutex);
            } else {
                c->bump = c->data;
                pthread_mutex_lock(&free_mutex);
                c->next = free_chunks;
                free_chunks = c;
                pthread_mutex_unlock(&free_mutex);
            }
            c = next;
        }

        pthread_mutex_lock(&sweep_mutex);
        sweep_pending = 0;
        pthread_cond_signal(&sweep_cond);
        pthread_mutex_unlock(&sweep_mutex);
    }
    return NULL;
}

static Chunk* acquire_chunk(void) {
    pthread_mutex_lock(&free_mutex);
    Chunk* c = free_chunks;
    if (c) {
        free_chunks = c->next;
        c->next = NULL;
        c->bump = c->data;
    }
    pthread_mutex_unlock(&free_mutex);
    if (!c) c = chunk_alloc();
    return c;
}

void gc_init(void) {
#if defined(__linux__)
    mallopt(M_MMAP_THRESHOLD, 8192);
#endif
    stack_top_hint = (char*)__builtin_frame_address(0);
    global_dtor = NULL;
    global_tracer = NULL;
    alloc_count = 0;
    gc_running = 0;
    sweep_pending = 0;
    shutdown_requested = 0;
    worklist = NULL;
    worklist_count = 0;
    worklist_cap = 0;
    sweep_queue = NULL;
    free_chunks = NULL;
    all_chunks_mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    sweep_mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    sweep_cond = (pthread_cond_t)PTHREAD_COND_INITIALIZER;
    free_mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;

    active_chunk = chunk_alloc();
    all_chunks = active_chunk;

    pthread_create(&sweep_thread, NULL, sweep_worker, NULL);
}

void gc_set_destructor(GcDestructor dtor) {
    global_dtor = dtor;
}

void gc_set_tracer(GcTraceFn fn) {
    global_tracer = fn;
}

void* gc_alloc(size_t size) {
    size_t total = align8(HDR_SIZE + size);
    if (active_chunk->bump + total > active_chunk->data + CHUNK_DATA_SIZE) {
        Chunk* c = acquire_chunk();
        if (!c) {
            fprintf(stderr, "\nerror [M1]: Out of Memory\n");
            exit(1);
        }
        c->next = all_chunks;
        all_chunks = c;
        active_chunk = c;
    }
    AllocHdr* hdr = (AllocHdr*)active_chunk->bump;
    hdr->magic = GC_MAGIC;
    hdr->size = size;
    hdr->mark = 0;
    hdr->padding = 0;
    active_chunk->bump += total;
    alloc_count++;
    if (alloc_count >= GC_INTERVAL)
        gc_collect();
    return get_ptr(hdr);
}

void gc_collect(void) {
    if (gc_running) return;
    gc_running = 1;
    worklist_count = 0;
    rebuild_sorted_chunks();
    {
        int nchunks = 0; Chunk* dc = all_chunks; while (dc) { nchunks++; dc = dc->next; }
    }

    mark_roots();
    process_worklist();

    Chunk* to_sweep = NULL;
    Chunk** tail = &to_sweep;
    Chunk** pp = &all_chunks;
    while (*pp) {
        if (*pp != active_chunk) {
            *tail = *pp;
            tail = &(*pp)->next;
            *pp = (*pp)->next;
            *tail = NULL;
        } else {
            pp = &(*pp)->next;
        }
    }

    pthread_mutex_lock(&sweep_mutex);
    while (sweep_pending)
        pthread_cond_wait(&sweep_cond, &sweep_mutex);
    sweep_queue = to_sweep;
    sweep_pending = 1;
    pthread_cond_signal(&sweep_cond);
    pthread_mutex_unlock(&sweep_mutex);

#if defined(__linux__)
    malloc_trim(0);
#endif
    alloc_count = 0;
    gc_running = 0;
}

void gc_shutdown(void) {
    pthread_mutex_lock(&sweep_mutex);
    shutdown_requested = 1;
    pthread_cond_signal(&sweep_cond);
    pthread_mutex_unlock(&sweep_mutex);
    pthread_join(sweep_thread, NULL);
    free(worklist);
}
#else

static void*** gc_slots = NULL;
static int gc_slot_count = 0;
static int gc_slot_cap = 0;
static int* gc_frame_stack = NULL;
static int gc_frame_stack_cap = 0;
static int gc_frame_depth = 0;

void boblang_gc_frame_begin(void) {
    if (gc_frame_depth >= gc_frame_stack_cap) {
        gc_frame_stack_cap = gc_frame_stack_cap ? gc_frame_stack_cap * 2 : 64;
        gc_frame_stack = (int*)realloc(gc_frame_stack, gc_frame_stack_cap * sizeof(int));
    }
    gc_frame_stack[gc_frame_depth++] = gc_slot_count;
}

void boblang_gc_frame_end(void) {
    if (gc_frame_depth > 0) gc_slot_count = gc_frame_stack[--gc_frame_depth];
}

void boblang_gc_register_slot(void** slot) {
    if (gc_slot_count >= gc_slot_cap) {
        gc_slot_cap = gc_slot_cap ? gc_slot_cap * 2 : 64;
        gc_slots = (void***)realloc(gc_slots, gc_slot_cap * sizeof(void**));
    }
    gc_slots[gc_slot_count++] = slot;
}

static void mark_grey(void* ptr) {
    AllocHdr* hdr = get_hdr(ptr);
    if (hdr->magic != GC_MAGIC) return;
    if (hdr->mark) return;
    hdr->mark = 1;
    if (worklist_count >= worklist_cap) {
        if (worklist_cap >= WORKLIST_MAX_CAP) return;
        int new_cap = worklist_cap ? worklist_cap * 2 : WORKLIST_INIT_CAP;
        if (new_cap > WORKLIST_MAX_CAP) new_cap = WORKLIST_MAX_CAP;
        void** wl = (void**)realloc(worklist, new_cap * sizeof(void*));
        if (!wl) return;
        worklist = wl;
        worklist_cap = new_cap;
    }
    worklist[worklist_count++] = ptr;
}

static void mark_roots(void) {
    for (int i = 0; i < gc_slot_count; i++) {
        if (gc_slots[i] && *gc_slots[i]) mark_grey(*gc_slots[i]);
    }
}

static void process_worklist(void) {
    int idx = 0;
    while (idx < worklist_count) {
        void* ptr = worklist[idx++];
        if (global_tracer)
            global_tracer(ptr, mark_grey);
    }
    worklist_count = 0;
}

static int sweep_chunk(Chunk* c) {
    char* p = c->data;
    int live = 0;
    while (p < c->bump) {
        AllocHdr* hdr = (AllocHdr*)p;
        if (hdr->magic != GC_MAGIC) {
            size_t hsz = hdr->size;
            if (!hsz) hsz = 8;
            p += align8(HDR_SIZE + hsz);
            continue;
        }
        size_t total = align8(HDR_SIZE + hdr->size);
        if (hdr->mark) {
            hdr->mark = 0;
            live = 1;
        } else {
            if (global_dtor) global_dtor(get_ptr(hdr));
            hdr->magic = 0;
        }
        p += total;
    }
    return live;
}

static Chunk* acquire_chunk(void) {
    Chunk* c = free_chunks;
    if (c) {
        free_chunks = c->next;
        c->next = NULL;
        c->bump = c->data;
        return c;
    }
    return chunk_alloc();
}

void gc_init(void) {
    global_dtor = NULL;
    global_tracer = NULL;
    alloc_count = 0;
    gc_running = 0;
    free_chunks = NULL;
    worklist = NULL;
    worklist_count = 0;
    worklist_cap = 0;
    active_chunk = chunk_alloc();
    all_chunks = active_chunk;
}

void gc_set_destructor(GcDestructor dtor) {
    global_dtor = dtor;
}

void gc_set_tracer(GcTraceFn fn) {
    global_tracer = fn;
}

void* gc_alloc(size_t size) {
    size_t total = align8(HDR_SIZE + size);
    if (active_chunk->bump + total > active_chunk->data + CHUNK_DATA_SIZE) {
        Chunk* c = acquire_chunk();
        if (!c) {
            fprintf(stderr, "\nerror [M1]: Out of Memory\n");
            exit(1);
        }
        c->next = all_chunks;
        all_chunks = c;
        active_chunk = c;
    }
    AllocHdr* hdr = (AllocHdr*)active_chunk->bump;
    hdr->magic = GC_MAGIC;
    hdr->size = size;
    hdr->mark = 0;
    hdr->padding = 0;
    active_chunk->bump += total;
    alloc_count++;
    if (alloc_count >= GC_INTERVAL)
        gc_collect();
    return get_ptr(hdr);
}

static void sweep_all(void) {
    Chunk* prev_active = active_chunk;
    Chunk** pp = &all_chunks;
    while (*pp) {
        Chunk* c = *pp;
        if (c == prev_active) {
            pp = &(*pp)->next;
            continue;
        }
        *pp = c->next;
        if (sweep_chunk(c)) {
            c->next = all_chunks;
            all_chunks = c;
        } else {
            c->bump = c->data;
            c->next = free_chunks;
            free_chunks = c;
        }
    }
}

void gc_collect(void) {
    if (gc_running) return;
    gc_running = 1;
    worklist_count = 0;
    mark_roots();
    process_worklist();
    sweep_all();
    alloc_count = 0;
    gc_running = 0;
}

void gc_shutdown(void) {
    free(worklist);
}
#endif
