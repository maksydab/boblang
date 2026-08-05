#ifndef GC_H
#define GC_H

#include <stddef.h>
#include <stdint.h>

#define GC_MAGIC 0x4743424C

typedef void (*GcDestructor)(void* ptr);
typedef void (*GcTraceFn)(void* ptr, void (*mark)(void*));

void  gc_init(void);
void  gc_set_destructor(GcDestructor dtor);
void  gc_set_tracer(GcTraceFn fn);
void* gc_alloc(size_t size);
void  gc_collect(void);
void  gc_shutdown(void);
void  gc_set_stack_top(void* addr);
void  boblang_gc_frame_begin(void);
void  boblang_gc_frame_end(void);
void  boblang_gc_register_slot(void** slot);

#endif
