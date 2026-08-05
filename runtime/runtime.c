#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include "gc.h"
#include <stdint.h>
#include <stdarg.h>
#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#elif !defined(__wasm__)
#include <sys/resource.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <dirent.h>
#endif

#define LIKELY(x)   __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

#define TAG_INT   1
#define TAG_BOOL  2
#define TAG_FLOAT 4

#define IS_TINT(p)   (((uintptr_t)(p)) & 1)
#define GET_TINT(p)  ((long long)(((intptr_t)(p)) >> 1))
#define MAKE_TINT(v) ((Object*)(uintptr_t)((((uintptr_t)(v)) << 1) | TAG_INT))

#define IS_TBOOL(p)  ((((uintptr_t)(p)) & 3) == TAG_BOOL)
#define GET_TBOOL(p) ((int)(((intptr_t)(p)) >> 2))
#define MAKE_TBOOL(v) ((Object*)(uintptr_t)((((uintptr_t)((v)!=0)) << 2) | TAG_BOOL))

#define IS_TFLOAT(p) ((((uintptr_t)(p)) & 7) == TAG_FLOAT)
#define GET_TFLOAT(p) ({ uint64_t _bits = (uint64_t)(uintptr_t)(p); _bits &= ~7ULL; double _d; memcpy(&_d, &_bits, 8); _d; })
#define MAKE_TFLOAT(v) ({ double _dv = (v); uint64_t _bits; memcpy(&_bits, &_dv, 8); (Object*)(uintptr_t)((_bits & ~7ULL) | TAG_FLOAT); })

#define IS_TAGGED(p) (((uintptr_t)(p)) & 7)

typedef enum {
    TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_STR, TYPE_LIST, TYPE_DICT, TYPE_FUNC, TYPE_PTR, TYPE_FOREIGN, TYPE_BIGI, TYPE_BIGF, TYPE_INTARRAY, TYPE_FLOATARRAY, TYPE_BOOLARRAY
} ValueType;

typedef struct Object Object;
struct Object {
    ValueType type;
    union {
        long long int_val;
        double float_val;
        int bool_val;
        void *ptr_val;
        struct { int len; char *data; } string;
        struct { int size; int capacity; Object **items; } list;
        struct { int size; int capacity; long long *items; } intlist;
        struct { int size; int capacity; double *items; } floatlist;
        struct { int size; int capacity; char *items; } boollist;
        struct { int size; int capacity; struct { Object *key; Object *value; } *entries; } dict;
        struct {
            void *ptr;
            int arity;
            int required_arity;
            Object *name;
            Object *bound_self;
            Object *arg_names;
            Object *defaults;
            int has_vararg;
        } func;
        struct {
            int type_id;
            void *ptr;
            Object *type_name;
        } foreign;
        struct { uint64_t w[4]; } bigi;      /* signed 256-bit integer (two's complement) */
        struct { uint64_t w[4]; int scale; } bigf;  /* bigf = w * 10^scale (w = i256 mantissa) */
    };
};

static Object _boblang_null_object = { .type = TYPE_INT, .int_val = 0 };
#define BOBLANG_NULL (&_boblang_null_object)
#define IS_NULL(p) ((p) == BOBLANG_NULL)

typedef Object* (*Fn0)();
typedef Object* (*Fn1)(Object*);
typedef Object* (*Fn2)(Object*, Object*);
typedef Object* (*Fn3)(Object*, Object*, Object*);
typedef Object* (*Fn4)(Object*, Object*, Object*, Object*);
typedef Object* (*Fn5)(Object*, Object*, Object*, Object*, Object*);
typedef Object* (*Fn6)(Object*, Object*, Object*, Object*, Object*, Object*);
typedef Object* (*Fn7)(Object*, Object*, Object*, Object*, Object*, Object*, Object*);
typedef Object* (*Fn8)(Object*, Object*, Object*, Object*, Object*, Object*, Object*, Object*);

Object* boblang_to_string(Object *obj);
void boblang_print(Object *obj);
Object* boblang_input(Object *prompt);
int boblang_is_truthy(Object *obj);
Object* boblang_bool_new(int val);
void boblang_dict_set(Object *dict, Object *key, Object *value);
Object* boblang_dict_get(Object *dict, Object *key);
Object* boblang_string_new(const char *val);
Object* boblang_immortal_string(const char *val);
void boblang_raise_error(int id, const char *msg, int line);
int bequals(Object *a, Object *b);
Object* boblang_type(Object *obj);
Object* boblang_int_new(long long val);
Object* boblang_lister_new();
void boblang_lister_append(Object *list, Object *value);
const char* boblang_unbox_str(Object *obj);
Object* boblang_get_property(Object *obj, Object *key);
void boblang_set_property(Object *obj, Object *key, Object *value);
Object* boblang_get_length(Object *obj);
Object* boblang_get_index(Object *obj, Object *idx);
void boblang_set_index(Object *obj, Object *idx, Object *value);
Object* boblang_runtime_call_method(Object *instance, Object *method_name, int argc, Object **args);
Object* boblang_runtime_call_method_va(Object *instance, Object *method_name, int argc, ...);
Object* boblang_instance_new(Object *cls);
Object* boblang_class_new(Object *name, Object *bases, Object *methods);
Object* boblang_dict_new();
Object* boblang_cast_int(Object *obj);
Object* boblang_cast_float(Object *obj);
Object* boblang_cast_bool(Object *obj);
Object* boblang_cast_str(Object *obj);
Object* boblang_len(Object *obj);
Object* boblang_range(Object *a, Object *b, Object *c);
long long boblang_unbox_int(Object *obj);
double boblang_unbox_float(Object *obj);
void* boblang_unbox_ptr(Object *obj);
Object* boblang_foreign_new(int type_id, void *ptr, Object *type_name);
int boblang_foreign_type_id(Object *obj);
Object* boblang_foreign_get_property(int type_id, void *ptr, const char *key);
Object* boblang_foreign_call_method(int type_id, void *ptr, const char *method, int argc, Object **args);
Object* boblang_null_new(void);
int boblang_is_null(Object *obj);
void boblang_set(Object *obj, Object *idx, Object *val);
void boblang_set_line(int line);
void boblang_set_file(const char* file);
void boblang_push_frame(const char* name);
void boblang_pop_frame();
Object* boblang_ptr_new(void* ptr);
Object* boblang_float_new(double val);
Object* boblang_func_new(void *ptr, int arity, int required_arity, Object *name, Object *bound_self, Object *arg_names, Object *defaults, int has_vararg);
Object* boblang_immortal_func(void *ptr, int arity, int required_arity, Object *name, Object *bound_self, Object *arg_names, Object *defaults, int has_vararg);
Object* boblang_call(Object *callable, Object **args, int argc, Object *kwargs_dict);
Object* boblang_list_get(Object *list, long long index);
void boblang_list_set(Object *list, long long index, Object *value);
long long boblang_list_len(Object *list);
void boblang_set_prop(Object *obj, const char *prop_name, Object *value);
Object* boblang_get(Object *obj, Object *idx);
Object* boblang_str_new(const char *val);
Object* boblang_slice(Object *obj, Object *start, Object *end);
int boblang_list_size_raw(Object *obj);
Object** boblang_list_items(Object *obj);
char* boblang_to_string_c(Object* obj);
void boblang_assert_type(Object *obj, char *expected, char *var_name, int line);
Object* badd(Object *a, Object *b);
Object* bsub(Object *a, Object *b);
Object* boblang_bigf_new(const char *decimal);
Object* boblang_bigi_new(const char *decimal);
Object* boblang_to_bigi(Object *obj);
Object* boblang_to_bigf(Object *obj);

extern Object* __boblang_rust_get_property(int type_id, void *ptr, const char *key);
extern Object* __boblang_rust_call_method(int type_id, void *ptr, const char *method, int argc, Object **args);

__attribute__((weak)) Object* __boblang_rust_get_property(int type_id, void *ptr, const char *key) {
    (void)type_id; (void)ptr; (void)key;
    return NULL;
}
__attribute__((weak)) Object* __boblang_rust_call_method(int type_id, void *ptr, const char *method, int argc, Object **args) {
    (void)type_id; (void)ptr; (void)method; (void)argc; (void)args;
    return NULL;
}
Object* bmul(Object *a, Object *b);
Object* bdiv(Object *a, Object *b);
Object* bpow(Object *a, Object *b);
Object* bmod(Object *a, Object *b);
Object* bidiv(Object *a, Object *b);
Object* beq(Object *a, Object *b);
Object* bneq(Object *a, Object *b);
Object* bgt(Object *a, Object *b);
Object* blt(Object *a, Object *b);
Object* bge(Object *a, Object *b);
Object* ble(Object *a, Object *b);
Object* boblang_and(Object *a, Object *b);
Object* boblang_or(Object *a, Object *b);
Object* boblang_not(Object *a);

int current_line = 0;
int boblang_recursion_depth = 0;
int boblang_tail_iterations = 0;
static char current_file[256] = "unknown";

__attribute__((constructor)) static void boblang_raise_stack_limit(void) {
}
static const char* call_stack[256];
static char call_stack_files[256][256];
static int call_stack_lines[256];
static int stack_depth = 0;

volatile int boblang_error_occurred = 0;
volatile int boblang_error_protect = 0;
static int last_error_id = 0;
static char last_error_msg_buf[512];
static const char* last_error_msg = NULL;
Object* boblang_error_object(void);

enum {
    ERR_TYPE_MISMATCH = 1,
    ERR_NOT_CALLABLE = 2,
    ERR_INDEX_OOB = 3,
    ERR_MISSING_ARG = 4,
    ERR_TOO_MANY_ARGS = 5,
    ERR_UNDEFINED_VAR = 6,
    ERR_INVALID_OP = 7,
    ERR_CALL_NIL = 8,
    ERR_OOM = 9,
    ERR_ASSIGN_NON_INDEXABLE = 10,
    ERR_LIST_INDEX_OOB = 11,
    ERR_UNBOX_NIL = 12,
    ERR_TOO_MANY_ARGS_MAX8 = 13,
    ERR_SLICE_TARGET = 14,
    ERR_INT_EMPTY_STR = 15,
    ERR_INT_BAD_STR = 16,
    ERR_TYPE_ASSERT_FAILED = 17,
    ERR_MODULO_ZERO = 18,
    ERR_INT_DIV_ZERO = 19,
    ERR_METHOD_NAME_NOT_STR = 20,
    ERR_METHOD_NOT_FOUND = 21,
    ERR_SORT_NEEDS_LIST = 22,
    ERR_APPEND_NEEDS_LIST = 23,
    ERR_POP_NEEDS_LIST = 24,
    ERR_POP_EMPTY_LIST = 25,
    ERR_CLEAR_NEEDS_LIST = 26,
    ERR_REVERSE_NEEDS_LIST = 27,
    ERR_INDEX_NON_INDEXABLE = 28,
    ERR_NOT_CALLABLE_TARGET = 29,
    ERR_VAR_INVOKE = 30,
    ERR_ASSIGN_NULL = 31,
};
/* ────────────────────────────────────────────────────────────────────────
 *  256-bit big numbers
 *
 *  bigi  = signed 256-bit integer (4 x uint64 little-endian, two's comp.)
 *  bigf  = decimal float:  value = (signed i256 mantissa) * 10^scale
 *          mantissa holds up to 77 significant decimal digits.
 * ──────────────────────────────────────────────────────────────────────── */

typedef struct { uint64_t w[4]; } I256;

#define BIG_MAX_MANT_DIGITS 77

static I256 i256_zero(void) { I256 z = {{0,0,0,0}}; return z; }
static int  i256_is_zero(I256 a) { return (a.w[0] | a.w[1] | a.w[2] | a.w[3]) == 0; }
static int  i256_is_neg(I256 a)  { return (a.w[3] >> 63) & 1; }

static I256 i256_from_u64(uint64_t v) { I256 r = {{v,0,0,0}}; return r; }
static I256 i256_from_i64(int64_t v) {
    I256 r;
    if (v >= 0) { r.w[0] = (uint64_t)v; r.w[1] = r.w[2] = r.w[3] = 0; }
    else        { r.w[0] = (uint64_t)v; r.w[1] = r.w[2] = r.w[3] = ~0ull; }
    return r;
}

static I256 i256_neg(I256 a) {
    I256 r;
    uint64_t carry = 1;
    for (int i = 0; i < 4; i++) {
        uint64_t t = (~a.w[i]) + carry;
        r.w[i] = t;
        carry = t < carry ? 1 : 0; /* overflow when t wraps past ~0 */
    }
    return r;
}
static I256 i256_abs(I256 a) { return i256_is_neg(a) ? i256_neg(a) : a; }

static I256 i256_add(I256 a, I256 b) {
    I256 r; uint64_t carry = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t lo = a.w[i] + b.w[i];
        uint64_t c1 = lo < a.w[i] ? 1 : 0;
        uint64_t sum = lo + carry;
        uint64_t c2 = sum < lo ? 1 : 0;
        r.w[i] = sum;
        carry = c1 | c2;
    }
    return r;
}
static I256 i256_sub(I256 a, I256 b) { return i256_add(a, i256_neg(b)); }

static int i256_cmp(I256 a, I256 b) {
    for (int i = 3; i >= 0; i--) {
        if (a.w[i] < b.w[i]) return -1;
        if (a.w[i] > b.w[i]) return  1;
    }
    return 0;
}

static I256 i256_shl1(I256 a) {
    uint64_t carry = 0;
    I256 r;
    for (int i = 0; i < 4; i++) {
        uint64_t nc = a.w[i] >> 63;
        r.w[i] = (a.w[i] << 1) | carry;
        carry = nc;
    }
    return r;
}

#if defined(__SIZEOF_INT128__)
static I256 i256_mul(I256 a, I256 b) {
    uint64_t res[8] = {0};
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            unsigned __int128 t = (unsigned __int128)a.w[i] * b.w[j];
            uint64_t lo = (uint64_t)t, hi = (uint64_t)(t >> 64);
            int k = i + j;
            uint64_t carry = lo;
            while (carry && k < 8) { uint64_t s = res[k] + carry; carry = s < res[k]; res[k] = s; k++; }
            k = i + j + 1;
            carry = hi;
            while (carry && k < 8) { uint64_t s = res[k] + carry; carry = s < res[k]; res[k] = s; k++; }
        }
    }
    I256 r = {{res[0], res[1], res[2], res[3]}};
    return r;
}
#else
static void mul64x64(uint64_t a, uint64_t b, uint64_t *hi, uint64_t *lo) {
    uint64_t a_lo = a & 0xffffffffULL, a_hi = a >> 32;
    uint64_t b_lo = b & 0xffffffffULL, b_hi = b >> 32;
    uint64_t p00 = a_lo * b_lo;
    uint64_t p01 = a_lo * b_hi;
    uint64_t p10 = a_hi * b_lo;
    uint64_t p11 = a_hi * b_hi;
    uint64_t mid = (p00 >> 32) + (p01 & 0xffffffffULL) + (p10 & 0xffffffffULL);
    *lo = (p00 & 0xffffffffULL) | (mid << 32);
    *hi = (p01 >> 32) + (p10 >> 32) + p11 + (mid >> 32);
}
static I256 i256_mul(I256 a, I256 b) {
    uint64_t res[8] = {0};
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            uint64_t hi, lo;
            mul64x64(a.w[i], b.w[j], &hi, &lo);
            int k = i + j;
            uint64_t carry = lo;
            while (carry && k < 8) { uint64_t s = res[k] + carry; carry = s < res[k]; res[k] = s; k++; }
            k = i + j + 1;
            carry = hi;
            while (carry && k < 8) { uint64_t s = res[k] + carry; carry = s < res[k]; res[k] = s; k++; }
        }
    }
    I256 r = {{res[0], res[1], res[2], res[3]}};
    return r;
}
#endif

static uint64_t udiv128_64(uint64_t n_hi, uint64_t n_lo, uint64_t d, uint64_t *rem_out) {
    /* bit-by-bit unsigned 128 / 64 division; correct on all targets */
    uint64_t q = 0, r = 0;
    for (int i = 127; i >= 0; i--) {
        uint64_t bit = i >= 64 ? ((n_hi >> (i - 64)) & 1) : ((n_lo >> i) & 1);
        uint64_t low = (r << 1) | bit;
        uint64_t r_ovf = r >> 63;   /* r >= 2^63 before shift -> shifted value >= 2^64 */
        if (r_ovf) {
            r = low + ((uint64_t)0 - d);   /* (2^64 - d) + low ; low < d guaranteed */
            q |= (uint64_t)1 << i;
        } else if (low >= d) {
            r = low - d;
            q |= (uint64_t)1 << i;
        } else {
            r = low;
        }
    }
    if (rem_out) *rem_out = r;
    return q;
}

static uint64_t i256_divmod_u64(I256 a, uint64_t d, I256 *out_q) {
    uint64_t rem = 0;
    I256 q = i256_zero();
    for (int i = 3; i >= 0; i--) {
        q.w[i] = udiv128_64(rem, a.w[i], d, &rem);
    }
    if (out_q) *out_q = q;
    return rem;
}

static I256 i256_udiv(I256 a, I256 b, I256 *rem_out) {
    I256 rem = i256_zero();
    I256 q = i256_zero();
    if (i256_is_zero(b)) return q;
    for (int bit = 255; bit >= 0; bit--) {
        uint64_t a_bit = (a.w[bit >> 6] >> (bit & 63)) & 1;
        rem = i256_shl1(rem);
        rem.w[0] |= a_bit;
        if (i256_cmp(rem, b) >= 0) {
            rem = i256_sub(rem, b);
            q.w[bit >> 6] |= (1ull << (bit & 63));
        }
    }
    if (rem_out) *rem_out = rem;
    return q;
}

static I256 i256_sdiv(I256 a, I256 b, I256 *rem_out) {
    int an = i256_is_neg(a), bn = i256_is_neg(b);
    I256 ua = an ? i256_neg(a) : a;
    I256 ub = bn ? i256_neg(b) : b;
    I256 r;
    I256 q = i256_udiv(ua, ub, &r);
    if (an != bn) q = i256_neg(q);
    if (rem_out) *rem_out = an ? i256_neg(r) : r;
    return q;
}

static int i256_bits(I256 a) {
    I256 u = i256_abs(a);
    if (i256_is_zero(u)) return 0;
    for (int i = 3; i >= 0; i--) {
        if (u.w[i] == 0) continue;
        uint64_t v = u.w[i];
        int b = 0;
        while (v) { b++; v >>= 1; }
        return 64 * i + b;
    }
    return 0;
}
static int i256_decimal_digits(I256 a) {
    int bits = i256_bits(a);
    if (bits == 0) return 1;
    return (int)((double)bits * 0.3010299956639812) + 1;
}

static double i256_to_double(I256 a) {
    int neg = i256_is_neg(a);
    I256 u = neg ? i256_neg(a) : a;
    double d = (double)u.w[3] * 6.2771017353866808e57;
    d += (double)u.w[2] * 3.4028236692093846e38;
    d += (double)u.w[1] * 1.8446744073709552e19;
    d += (double)u.w[0];
    return neg ? -d : d;
}

static int i256_from_str(const char *s, I256 *out) {
    if (!s) return -1;
    int neg = 0;
    const char *p = s;
    if (*p == '-') { neg = 1; p++; }
    else if (*p == '+') p++;
    if (*p == 0) return -1;
    I256 acc = i256_zero();
    int digits = 0;
    for (; *p; p++) {
        if (*p < '0' || *p > '9') return -1;
        acc = i256_add(i256_mul(acc, i256_from_u64(10)), i256_from_u64((uint64_t)(*p - '0')));
        if (++digits > 80) break; /* cap: wraps past 256 bits for absurd inputs */
    }
    if (out) *out = neg ? i256_neg(acc) : acc;
    return 0;
}

static void i256_to_str_buf(I256 v, char *buf, size_t sz) {
    if (sz == 0) return;
    int neg = i256_is_neg(v);
    I256 u = neg ? i256_neg(v) : v;
    if (i256_is_zero(u)) { snprintf(buf, sz, "0"); return; }
    char tmp[100];
    int idx = 0;
    while (!i256_is_zero(u) && idx < (int)sizeof(tmp) - 1) {
        I256 q;
        uint64_t r = i256_divmod_u64(u, 10, &q);
        tmp[idx++] = '0' + (char)r;
        u = q;
    }
    int len = 0;
    if (neg) buf[len++] = '-';
    for (int k = idx - 1; k >= 0 && len < (int)sz - 1; k--) buf[len++] = tmp[k];
    buf[len] = 0;
}

static int64_t i256_to_i64_trunc(I256 v) {
    /* truncate toward zero to the low 64 bits of the magnitude */
    I256 u = i256_is_neg(v) ? i256_neg(v) : v;
    uint64_t low = u.w[0];
    return i256_is_neg(v) ? -(int64_t)low : (int64_t)low;
}

/* ---- decimal float (bigf) helpers ---- */
static void bigf_shift(I256 m, int shift, I256 *out, int *overflowed) {
    /* out = m * 10^shift ; overflowed set if it does not fit 256 bits */
    *overflowed = 0;
    if (shift <= 0) { *out = m; return; }
    if (i256_decimal_digits(m) + shift > BIG_MAX_MANT_DIGITS + 1) { *overflowed = 1; *out = i256_zero(); return; }
    I256 acc = m;
    for (int i = 0; i < shift; i++) {
        acc = i256_mul(acc, i256_from_u64(10));
        if (i256_decimal_digits(acc) > BIG_MAX_MANT_DIGITS + 1) { *overflowed = 1; *out = i256_zero(); return; }
    }
    *out = acc;
}

static int bigf_from_str(const char *s, I256 *out_m, int *out_scale) {
    if (!s) return -1;
    int neg = 0;
    const char *p = s;
    if (*p == '-') { neg = 1; p++; }
    else if (*p == '+') p++;
    I256 m = i256_zero();
    int frac = 0;
    int frac_digits = 0;
    int have = 0;
    int kept = 0;
    int total_digits = 0;
    for (; *p; p++) {
        if (*p >= '0' && *p <= '9') {
            if (kept < BIG_MAX_MANT_DIGITS) {
                m = i256_add(i256_mul(m, i256_from_u64(10)), i256_from_u64((uint64_t)(*p - '0')));
                kept++;
            }
            if (frac) frac_digits++;
            total_digits++;
            have = 1;
        } else if (*p == '.') {
            if (frac) return -1;
            frac = 1;
        } else if (*p == 'e' || *p == 'E') {
            p++;
            int eneg = 0;
            if (*p == '-') { eneg = 1; p++; }
            else if (*p == '+') p++;
            int e = 0;
            for (; *p; p++) {
                if (*p < '0' || *p > '9') return -1;
                e = e * 10 + (*p - '0');
                if (e > 1000000) e = 1000000;
            }
            int scale = (total_digits - kept) - frac_digits + (eneg ? -e : e);
            if (out_scale) *out_scale = scale;
            if (out_m) *out_m = neg ? i256_neg(m) : m;
            return have ? 0 : -1;
        } else {
            return -1;
        }
    }
    if (out_scale) *out_scale = (total_digits - kept) - frac_digits;
    if (out_m) *out_m = neg ? i256_neg(m) : m;
    return have ? 0 : -1;
}

static void bigf_to_str_buf(I256 m, int scale, char *buf, size_t sz) {
    if (sz == 0) return;
    int neg = i256_is_neg(m);
    I256 u = neg ? i256_neg(m) : m;
    if (i256_is_zero(u)) { snprintf(buf, sz, "0"); return; }
    char digits[110];
    int nd = 0;
    while (!i256_is_zero(u) && nd < (int)sizeof(digits) - 1) {
        I256 q;
        digits[nd++] = '0' + (char)i256_divmod_u64(u, 10, &q);
        u = q;
    }
    int len = 0;
    if (neg) buf[len++] = '-';
    if (scale >= 0) {
        for (int k = nd - 1; k >= 0 && len < (int)sz - 1; k--) buf[len++] = digits[k];
        for (int i = 0; i < scale && len < (int)sz - 1; i++) buf[len++] = '0';
    } else {
        int point = -scale;
        if (point >= nd) {
            buf[len++] = '0';
            buf[len++] = '.';
            int z = point - nd;
            for (int i = 0; i < z && len < (int)sz - 1; i++) buf[len++] = '0';
            for (int k = nd - 1; k >= 0 && len < (int)sz - 1; k--) buf[len++] = digits[k];
        } else {
            int int_part = nd - point;
            for (int k = nd - 1; k >= nd - int_part && len < (int)sz - 1; k--) buf[len++] = digits[k];
            buf[len++] = '.';
            for (int k = nd - int_part - 1; k >= 0 && len < (int)sz - 1; k--) buf[len++] = digits[k];
        }
        while (len > 0 && buf[len - 1] == '0') len--;
        if (len > 0 && buf[len - 1] == '.') len--;
    }
    buf[len] = 0;
    if (len == 0) snprintf(buf, sz, "0");
}

static void bigf_add(I256 am, int as, I256 bm, int bs, I256 *rm, int *rs) {
    int s = as < bs ? as : bs;
    I256 x = am, y = bm;
    int dx = as - s, dy = bs - s;
    int ox = 0, oy = 0;
    if (dx > 0) bigf_shift(am, dx, &x, &ox);
    if (dy > 0) bigf_shift(bm, dy, &y, &oy);
    if (ox && !oy) { *rm = am; *rs = as; return; }   /* am dominates */
    if (oy && !ox) { *rm = bm; *rs = bs; return; }   /* bm dominates */
    *rm = i256_add(x, y);
    *rs = s;
}

static void bigf_sub(I256 am, int as, I256 bm, int bs, I256 *rm, int *rs) {
    int s = as < bs ? as : bs;
    I256 x = am, y = bm;
    int dx = as - s, dy = bs - s;
    int ox = 0, oy = 0;
    if (dx > 0) bigf_shift(am, dx, &x, &ox);
    if (dy > 0) bigf_shift(bm, dy, &y, &oy);
    if (ox && !oy) { *rm = am; *rs = as; return; }   /* am dominates */
    if (oy && !ox) { *rm = i256_neg(bm); *rs = bs; return; } /* bm dominates */
    *rm = i256_sub(x, y);
    *rs = s;
}

static int bigf_cmp(I256 am, int as, I256 bm, int bs) {
    /* sign shortcut */
    int an = i256_is_neg(am), bn = i256_is_neg(bm);
    if (an != bn) return an ? -1 : 1;
    if (i256_is_zero(am) && i256_is_zero(bm)) return 0;
    if (an) return -bigf_cmp(i256_neg(am), as, i256_neg(bm), bs);
    int s = as < bs ? as : bs;
    I256 x = am, y = bm;
    int dx = as - s, dy = bs - s;
    int ox = 0, oy = 0;
    if (dx > 0) bigf_shift(am, dx, &x, &ox);
    if (dy > 0) bigf_shift(bm, dy, &y, &oy);
    if (ox && !oy) return 1;  /* am dominates */
    if (oy && !ox) return -1; /* bm dominates */
    return i256_cmp(x, y);
}

static void bigf_mul(I256 am, int as, I256 bm, int bs, I256 *rm, int *rs) {
    *rm = i256_mul(am, bm);
    *rs = as + bs;
}

static void bigf_div(I256 am, int as, I256 bm, int bs, I256 *rm, int *rs) {
    if (i256_is_zero(bm)) {
        boblang_raise_error(ERR_INT_DIV_ZERO, NULL, current_line);
        *rm = i256_zero(); *rs = 0; return;
    }
    int p = BIG_MAX_MANT_DIGITS - i256_decimal_digits(am);
    if (p < 0) p = 0;
    if (p > 45) p = 45;
    I256 dividend;
    int ov = 0;
    bigf_shift(am, p, &dividend, &ov);
    if (ov) { dividend = am; p = 0; }
    I256 q = i256_sdiv(dividend, bm, NULL);
    *rm = q;
    *rs = as - bs - p;
}

static I256 bigf_to_i256(I256 m, int scale) {
    if (i256_is_zero(m)) return m;
    if (scale >= 0) {
        I256 r;
        int ov;
        bigf_shift(m, scale, &r, &ov);
        return ov ? i256_zero() : r;
    }
    int neg = i256_is_neg(m);
    I256 u = neg ? i256_neg(m) : m;
    for (int i = 0; i < -scale; i++) u = i256_sdiv(u, i256_from_u64(10), NULL);
    return neg ? i256_neg(u) : u;
}

static double bigf_to_double(I256 m, int scale) {
    char buf[130];
    bigf_to_str_buf(m, scale, buf, sizeof(buf));
    return strtod(buf, NULL);
}


const char* boblang_error_message(int id) {
    switch (id) {
        case ERR_TYPE_MISMATCH: return "Runtime Error: Type mismatch - incompatible types.";
        case ERR_NOT_CALLABLE: return "Runtime Error: Attempted to call a value that is not callable.";
        case ERR_INDEX_OOB: return "Runtime Error: Index out of bounds.";
        case ERR_MISSING_ARG: return "Runtime Error: Missing argument in function call.";
        case ERR_TOO_MANY_ARGS: return "Runtime Error: Too many arguments in function call.";
        case ERR_UNDEFINED_VAR: return "Runtime Error: Attempted to reference a non-existent variable.";
        case ERR_INVALID_OP: return "Runtime Error: Invalid operation between incompatible types.";
        case ERR_CALL_NIL: return "Runtime Error: Attempted to call a nil value.";
        case ERR_OOM: return "Runtime Error: Out of memory.";
        case ERR_ASSIGN_NON_INDEXABLE: return "Runtime Error: cannot assign to non-indexable type.";
        case ERR_LIST_INDEX_OOB: return "Runtime Error: list index out of range.";
        case ERR_UNBOX_NIL: return "Runtime Error: Attempt to unbox or use a nil/null object as an integer.";
        case ERR_TOO_MANY_ARGS_MAX8: return "Runtime Error: Too many arguments for function call (max 8).";
        case ERR_SLICE_TARGET: return "Runtime Error: slice target must be list or string.";
        case ERR_INT_EMPTY_STR: return "Runtime Error: int() received an empty string.";
        case ERR_INT_BAD_STR: return "Runtime Error: int() requires a valid integer string, but the input could not be fully parsed as a number.";
        case ERR_TYPE_ASSERT_FAILED: return "Runtime Error: Type assertion failed.";
        case ERR_MODULO_ZERO: return "Runtime Error: Modulo by zero.";
        case ERR_INT_DIV_ZERO: return "Runtime Error: Integer division by zero.";
        case ERR_METHOD_NAME_NOT_STR: return "Runtime Error: Method name must be a string.";
        case ERR_METHOD_NOT_FOUND: return "Runtime Error: Method not found or not callable.";
        case ERR_SORT_NEEDS_LIST: return "Runtime Error: sort() requires a list.";
        case ERR_APPEND_NEEDS_LIST: return "Runtime Error: append() requires a list.";
        case ERR_POP_NEEDS_LIST: return "Runtime Error: pop() requires a list.";
        case ERR_POP_EMPTY_LIST: return "Runtime Error: pop() from empty list.";
        case ERR_CLEAR_NEEDS_LIST: return "Runtime Error: clear() requires a list.";
        case ERR_REVERSE_NEEDS_LIST: return "Runtime Error: reverse() requires a list.";
        case ERR_INDEX_NON_INDEXABLE: return "Runtime Error: cannot index non-indexable type.";
        case ERR_NOT_CALLABLE_TARGET: return "Runtime Error: Object is not a callable target function or class type.";
        case ERR_VAR_INVOKE: return "Runtime Error: Target cannot be invoked via variable invocation.";
        case ERR_ASSIGN_NULL: return "Runtime Error: cannot assign nil to a non-nullable variable.";
        default: return "Runtime Error: Unknown error.";
    }
}

// obfuscated build naem resolution
static unsigned long long boblang_fnv1a(const char* s) {
    unsigned long long h = 1469598103934665603ULL;
    while (*s) {
        h ^= (unsigned char)*s++;
        h *= 1099511628211ULL;
    }
    return h;
}

static void boblang_token_hex(const char* s, char out[17]) {
    unsigned long long h = boblang_fnv1a(s);
    for (int i = 15; i >= 0; i--) {
        out[i] = "0123456789abcdef"[h & 15];
        h >>= 4;
    }
    out[16] = 0;
}

// eeturns 1 and fills `out` with a filename in the current directory whose basename hashes to `token` a 16-hex-char FNV-1a token returns 0 otherwise.
static int boblang_find_file_by_token(const char* token, char* out, size_t outlen) {
    char hex[17];
#if defined(_WIN32)
    WIN32_FIND_DATAA fd;
    HANDLE hfind = FindFirstFileA("*", &fd);
    if (hfind == INVALID_HANDLE_VALUE) return 0;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
            boblang_token_hex(fd.cFileName, hex);
            if (strcmp(hex, token) == 0) {
                snprintf(out, outlen, "%s", fd.cFileName);
                FindClose(hfind);
                return 1;
            }
        }
    } while (FindNextFileA(hfind, &fd));
    FindClose(hfind);
    return 0;
#elif !defined(__wasm__)
    DIR* d = opendir(".");
    if (!d) return 0;
    struct dirent* e;
    while ((e = readdir(d))) {
        struct stat st;
        if (stat(e->d_name, &st) == 0 && S_ISREG(st.st_mode)) {
            boblang_token_hex(e->d_name, hex);
            if (strcmp(hex, token) == 0) {
                snprintf(out, outlen, "%s", e->d_name);
                closedir(d);
                return 1;
            }
        }
    }
    closedir(d);
    return 0;
#else
    (void)token; (void)out; (void)outlen;
    return 0;
#endif
}


static const char* boblang_resolve_error_file(const char* input, char* buf, size_t buflen) {
    if (boblang_find_file_by_token(input, buf, buflen)) return buf;
    return input;
}

void boblang_raise_error(int id, const char *msg, int line) {
    int err_line = (line > 0) ? line : current_line;
    last_error_id = id;
    if (msg) {
        snprintf(last_error_msg_buf, sizeof(last_error_msg_buf), "%s", msg);
        last_error_msg = last_error_msg_buf;
    } else {
        last_error_msg = NULL;
    }

    if (stack_depth > 0) {
        fprintf(stderr, "\nTraceback (most recent call last):\n");
        for (int i = stack_depth - 1; i >= 0; i--) {
            const char* fn = call_stack[i] ? call_stack[i] : "?";
            if (i == 0)
                fprintf(stderr, "  %s (entry)\n", fn);
            else
                fprintf(stderr, "  %s, called at %s:%d\n", fn, call_stack_files[i], call_stack_lines[i]);
        }
    }

    fprintf(stderr, "\n\033[1;31m%s\033[0m\n", boblang_error_message(id));
    if (msg) fprintf(stderr, "  \033[1;31m->\033[0m %s\n", msg);

    char err_file_buf[512];
    const char* err_file = boblang_resolve_error_file(current_file, err_file_buf, sizeof(err_file_buf));
    fprintf(stderr, "  at ./%s:%d\n", err_file, err_line);

    FILE *f = fopen(err_file, "r");
    if (f) {
        char buf[512];
        int l = 1;
        while (fgets(buf, sizeof(buf), f)) {
            if (l <= err_line + 2 && l >= err_line - 2) {
                fprintf(stderr, "%s%4d | %s", l == err_line ? "\033[1;31m" : "", l, buf);
                if (l == err_line) fprintf(stderr, "\033[0m");
            }
            if (l == err_line + 2) break;
            l++;
        }
        fclose(f);
    }

    if (line > 0) current_line = line;
    boblang_error_occurred = 1;
    if (boblang_error_protect) return;
    exit(1);
}

Object* boblang_error_object(void) {
    char buf[512];
    if (last_error_msg && last_error_msg[0] != '\0') {
        snprintf(buf, sizeof(buf), "%s", last_error_msg);
    } else {
        snprintf(buf, sizeof(buf), "%s", boblang_error_message(last_error_id));
    }
    last_error_id = 0;
    last_error_msg = NULL;
    return boblang_string_new(buf);
}

int boblang_cli_argc = 0;
char **boblang_cli_argv = NULL;

Object* bob_print(Object*);
Object* bob_input(Object*);
Object* bob_int(Object*);
Object* bob_float(Object*);
Object* bob_str(Object*);
Object* bob_bool(Object*);
Object* bob_type(Object*);
Object* bob_len(Object*);
Object* bob_range(Object*, Object*, Object*);
Object* bob_min(Object*, Object*);
Object* bob_max(Object*, Object*);
Object* bob_clamp(Object*, Object*, Object*);
Object* bob_ascii(Object*);
Object* bob_chr(Object*);
Object* boblang_list_sort_impl(Object*);
Object* boblang_list_append_impl(Object*, Object*);
Object* boblang_list_pop_impl(Object*);
Object* boblang_list_clear_impl(Object*);
Object* boblang_list_reverse_impl(Object*);
Object* boblang_list_map_impl(Object*, Object*);
Object* boblang_list_filter_impl(Object*, Object*);
Object* boblang_list_reduce_impl(Object*, Object*);

Object* bob_get_args(void);

Object *STR_CLASS;
Object *STR_BASES;
Object *STR_LENGTH;
Object *STR_NAME;
Object *STR_INIT;
Object *STR_CALL;
Object *STR_SPACE;
Object *STR_NEWLINE;
Object *STR_PROPS;
Object *FUNC_PRINT;
Object *FUNC_INPUT;
Object *FUNC_INT;
Object *FUNC_FLOAT;
Object *FUNC_STR;
Object *FUNC_BOOL;
Object *FUNC_TYPE;
Object *FUNC_LEN;
Object *FUNC_RANGE;
Object *FUNC_MIN;
Object *FUNC_MAX;
Object *FUNC_CLAMP;
Object *FUNC_ASCII;
Object *FUNC_CHR;
Object *FUNC_LIST_SORT;
Object *FUNC_LIST_APPEND;
Object *FUNC_LIST_POP;
Object *FUNC_LIST_CLEAR;
Object *FUNC_LIST_REVERSE;
Object *FUNC_LIST_MAP;
Object *FUNC_LIST_FILTER;
Object *FUNC_LIST_REDUCE;
Object *FUNC_GET_ARGS;

static void object_destructor(void* ptr) {
    Object* obj = (Object*)ptr;
    if (obj->type == TYPE_LIST) {
        free(obj->list.items);
    } else if (obj->type == TYPE_INTARRAY) {
        free(obj->intlist.items);
    } else if (obj->type == TYPE_FLOATARRAY) {
        free(obj->floatlist.items);
    } else if (obj->type == TYPE_BOOLARRAY) {
        free(obj->boollist.items);
    } else if (obj->type == TYPE_DICT) {
        free(obj->dict.entries);
    }
}

static void trace_object_children(void* ptr, void (*mark)(void*)) {
    Object* obj = (Object*)ptr;
    if (obj->type == TYPE_LIST) {
        for (int i = 0; i < obj->list.size; i++)
            mark(obj->list.items[i]);
    } else if (obj->type == TYPE_DICT) {
        for (int i = 0; i < obj->dict.capacity; i++) {
            if (obj->dict.entries[i].key) {
                mark(obj->dict.entries[i].key);
                mark(obj->dict.entries[i].value);
            }
        }
    } else if (obj->type == TYPE_FUNC) {
        mark(obj->func.bound_self);
        mark(obj->func.arg_names);
        mark(obj->func.defaults);
    } else if (obj->type == TYPE_FOREIGN) {
        mark(obj->foreign.type_name);
    }
}

__attribute__((constructor))
void boblang_init_globals(void) {
    gc_init();
    gc_set_destructor(object_destructor);
    gc_set_tracer(trace_object_children);
    STR_CLASS   = boblang_immortal_string("__class__");
    STR_BASES   = boblang_immortal_string("__bases__");
    STR_LENGTH  = boblang_immortal_string("length");
    STR_NAME    = boblang_immortal_string("__name__");
    STR_PROPS   = boblang_immortal_string("props");
    STR_INIT    = boblang_immortal_string("_init_");
    STR_CALL    = boblang_immortal_string("__call__");
    STR_SPACE   = boblang_immortal_string(" ");
    STR_NEWLINE = boblang_immortal_string("\n");

    FUNC_PRINT  = boblang_immortal_func((void*)bob_print, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_INPUT  = boblang_immortal_func((void*)bob_input, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_INT    = boblang_immortal_func((void*)bob_int, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_FLOAT  = boblang_immortal_func((void*)bob_float, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_STR    = boblang_immortal_func((void*)bob_str, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_BOOL   = boblang_immortal_func((void*)bob_bool, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_TYPE   = boblang_immortal_func((void*)bob_type, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_LEN    = boblang_immortal_func((void*)bob_len, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_RANGE  = boblang_immortal_func((void*)bob_range, 3, 3, NULL, NULL, NULL, NULL, 0);
    FUNC_MIN    = boblang_immortal_func((void*)bob_min, 2, 2, NULL, NULL, NULL, NULL, 0);
    FUNC_MAX    = boblang_immortal_func((void*)bob_max, 2, 2, NULL, NULL, NULL, NULL, 0);
    FUNC_CLAMP  = boblang_immortal_func((void*)bob_clamp, 3, 3, NULL, NULL, NULL, NULL, 0);
    FUNC_ASCII  = boblang_immortal_func((void*)bob_ascii, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_CHR    = boblang_immortal_func((void*)bob_chr, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_SORT   = boblang_immortal_func((void*)boblang_list_sort_impl, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_APPEND = boblang_immortal_func((void*)boblang_list_append_impl, 2, 2, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_POP    = boblang_immortal_func((void*)boblang_list_pop_impl, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_CLEAR  = boblang_immortal_func((void*)boblang_list_clear_impl, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_REVERSE = boblang_immortal_func((void*)boblang_list_reverse_impl, 1, 1, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_MAP    = boblang_immortal_func((void*)boblang_list_map_impl, 2, 2, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_FILTER = boblang_immortal_func((void*)boblang_list_filter_impl, 2, 2, NULL, NULL, NULL, NULL, 0);
    FUNC_LIST_REDUCE = boblang_immortal_func((void*)boblang_list_reduce_impl, 2, 2, NULL, NULL, NULL, NULL, 0);
    FUNC_GET_ARGS    = boblang_immortal_func((void*)bob_get_args, 0, 0, NULL, NULL, NULL, NULL, 0);
}


long long boblang_unbox_int(Object *obj) {
    if (UNLIKELY(!obj)) {
        boblang_raise_error(ERR_UNBOX_NIL, NULL, current_line);
        return 0;
    }
    if (LIKELY(IS_TINT(obj))) return GET_TINT(obj);
    if (IS_TFLOAT(obj)) return (long long)GET_TFLOAT(obj);
    if (IS_TBOOL(obj)) return GET_TBOOL(obj);
    if (IS_NULL(obj)) return 0;
    switch (obj->type) {
        case TYPE_INT:   return obj->int_val;
        case TYPE_FLOAT: return (long long)obj->float_val;
        case TYPE_BIGI: {
            I256 v = {{obj->bigi.w[0], obj->bigi.w[1], obj->bigi.w[2], obj->bigi.w[3]}};
            return i256_to_i64_trunc(v);
        }
        case TYPE_BIGF: {
            I256 m = {{obj->bigf.w[0], obj->bigf.w[1], obj->bigf.w[2], obj->bigf.w[3]}};
            return i256_to_i64_trunc(bigf_to_i256(m, obj->bigf.scale));
        }
        default: return 0;
    }
}
Object* boblang_get_length(Object *obj) {
    if (IS_TAGGED(obj)) return boblang_int_new(0);

    switch (obj->type) {
        case TYPE_LIST:
            return boblang_int_new(obj->list.size);
        case TYPE_INTARRAY:
            return boblang_int_new(obj->intlist.size);
        case TYPE_FLOATARRAY:
            return boblang_int_new(obj->floatlist.size);
        case TYPE_BOOLARRAY:
            return boblang_int_new(obj->boollist.size);
        case TYPE_DICT:
            return boblang_int_new(obj->dict.size);
        case TYPE_STR:
            return boblang_int_new(obj->string.len);
        default:
            return boblang_int_new(0);
    }
}
double boblang_unbox_float(Object *obj) {
    if(UNLIKELY(!obj)) return 0.0;
    if (IS_TFLOAT(obj)) return GET_TFLOAT(obj);
    if (IS_TINT(obj)) return (double)GET_TINT(obj);
    if (IS_TBOOL(obj)) return (double)GET_TBOOL(obj);
    if (!IS_TAGGED(obj)) {
        if (obj->type == TYPE_FLOAT) return obj->float_val;
        if (obj->type == TYPE_BIGI) {
            I256 v = {{obj->bigi.w[0], obj->bigi.w[1], obj->bigi.w[2], obj->bigi.w[3]}};
            return i256_to_double(v);
        }
        if (obj->type == TYPE_BIGF) {
            I256 m = {{obj->bigf.w[0], obj->bigf.w[1], obj->bigf.w[2], obj->bigf.w[3]}};
            return bigf_to_double(m, obj->bigf.scale);
        }
    }
    return 0.0;
}

const char* boblang_unbox_str(Object* obj) {
    if (UNLIKELY(!obj)) return "";
    if (IS_TAGGED(obj)) return "";
    if (obj->type == TYPE_STR) {
        return obj->string.data;
    }
    return "";
}
void* boblang_unbox_ptr(Object *obj) {
    if (IS_TAGGED(obj)) return NULL;
    return (obj && obj->type == TYPE_PTR) ? obj->ptr_val : NULL;
}

void boblang_set_line(int line) {
    current_line = line;
}

void boblang_set(Object *obj, Object *idx, Object *val) {
    if (UNLIKELY(!obj || IS_TAGGED(obj))) {
        boblang_raise_error(ERR_ASSIGN_NON_INDEXABLE, NULL, current_line);
        return;
    }
    if (obj->type == TYPE_LIST) {
        long long i = boblang_unbox_int(idx);
        if (UNLIKELY(i < 0 || i >= obj->list.size)) boblang_raise_error(ERR_LIST_INDEX_OOB, NULL, current_line);
        obj->list.items[i] = val;
    } else if (obj->type == TYPE_DICT) {
        boblang_dict_set(obj, idx, val);
    } else {
        boblang_raise_error(ERR_ASSIGN_NON_INDEXABLE, NULL, current_line);
    }
}
Object* boblang_runtime_call_callable(Object *callable, int argc, ...) {
    va_list args;
    va_start(args, argc);
    Object *arg_array[16];
    for (int i = 0; i < argc; i++) {
        arg_array[i] = va_arg(args, Object*);
    }
    va_end(args);

    if (!callable || IS_TAGGED(callable)) {
        boblang_raise_error(ERR_NOT_CALLABLE_TARGET, NULL, current_line);
        return NULL;
    }

    if (callable->type == TYPE_DICT) {
        Object *is_class_indicator = boblang_dict_get(callable, STR_NAME);
        if (is_class_indicator) {
            Object *instance = boblang_instance_new(callable);
            Object *init_method = boblang_dict_get(callable, STR_INIT);
            if (init_method && !IS_TAGGED(init_method) && init_method->type == TYPE_FUNC) {
                Object **init_args = malloc(sizeof(Object*) * (argc + 1));
                init_args[0] = instance;
                for (int i = 0; i < argc; i++) init_args[i + 1] = arg_array[i];
                boblang_call(init_method, init_args, argc + 1, NULL);
                free(init_args);
            }
            return instance;
        }
    }

    if (callable->type == TYPE_FUNC) {
        return boblang_call(callable, arg_array, argc, NULL);
    }

    boblang_raise_error(ERR_VAR_INVOKE, NULL, current_line);
    return NULL;
}
void boblang_set_file(const char* file) {
    strncpy(current_file, file, sizeof(current_file)-1);
}

void boblang_set_stack_top(void) {
    char probe;
    gc_set_stack_top((void*)&probe);
}

void boblang_push_frame(const char* name) {
    if (stack_depth < 256) {
        call_stack[stack_depth] = name;
        strncpy(call_stack_files[stack_depth], current_file, sizeof(call_stack_files[stack_depth]) - 1);
        call_stack_lines[stack_depth] = current_line ? current_line : 1;
    }
    stack_depth++;
}

void boblang_pop_frame() {
    if (stack_depth > 0) {
        stack_depth--;
        if (stack_depth > 0)
            strncpy(current_file, call_stack_files[stack_depth], sizeof(current_file) - 1);
    }
}

static inline Object* alloc_obj(ValueType type, size_t extra) {
    Object *obj = (Object*) gc_alloc(sizeof(Object) + extra);
    if (UNLIKELY(!obj)) {
        boblang_raise_error(ERR_OOM, NULL, current_line);
    }
    obj->type = type;
    return obj;
}
void boblang_runtime_error(int error_code, const char* filename, int line) {
    fprintf(stderr, "\n\033[1;31m%s\033[0m\n", boblang_error_message(error_code));
    fprintf(stderr, "  \033[1;31m->\033[0m Execution halted with code %d\n", error_code);

    char err_file_buf[512];
    const char* err_file = boblang_resolve_error_file(filename, err_file_buf, sizeof(err_file_buf));
    fprintf(stderr, "  at %s:%d\n", err_file, line);

    FILE* file = fopen(err_file, "r");
    if (file) {
        char buffer[512];
        int current_line = 1;
        while (fgets(buffer, sizeof(buffer), file)) {
            if (current_line <= line + 2 && current_line >= line - 2) {
                fprintf(stderr, "%s%4d | %s", current_line == line ? "\033[1;31m" : "", current_line, buffer);
                if (buffer[strlen(buffer)-1] != '\n') fprintf(stderr, "\n");
                if (current_line == line) fprintf(stderr, "\033[0m");
            }
            if (current_line == line + 2) break;
            current_line++;
        }
        fclose(file);
    }
    exit(error_code);
}
Object* boblang_ptr_new(void* ptr) {
    Object *obj = alloc_obj(TYPE_PTR, 0);
    obj->ptr_val = ptr;
    return obj;
}

Object* boblang_int_new(long long val) {
    return MAKE_TINT(val);
}

Object* boblang_float_new(double val) {
    uint64_t bits;
    memcpy(&bits, &val, 8);
    if ((bits & 0x7FF0000000000000ULL) == 0x7FF0000000000000ULL || (bits & 3) != 0) {
        Object *obj = alloc_obj(TYPE_FLOAT, 0);
        obj->float_val = val;
        return obj;
    }
    return MAKE_TFLOAT(val);
}

Object* boblang_bool_new(int val) {
    return MAKE_TBOOL(val);
}

Object* boblang_null_new(void) {
    return BOBLANG_NULL;
}

#ifdef __wasm__
__attribute__((import_module("env"), import_name("boblang_js_invoke")))
Object* boblang_js_invoke(char* name, int argc, Object** args);
#else
static Object* boblang_js_invoke(char* name, int argc, Object** args) {
    (void)name; (void)argc; (void)args;
    return boblang_null_new();
}
#endif

Object* boblang_js_alloc(int size) {
    return malloc(size ? size : 1);
}

Object* boblang_str_from_js(char* ptr, int len) {
    if (len < 0) len = ptr ? strlen(ptr) : 0;
    Object* obj = alloc_obj(TYPE_STR, len + 1);
    obj->string.data = (char*)obj + sizeof(Object);
    if (ptr && len > 0) memcpy(obj->string.data, ptr, len);
    obj->string.data[len] = 0;
    obj->string.len = len;
    return obj;
}

int boblang_js_str_len(Object* o) {
    if (!o || IS_TAGGED(o) || o->type != TYPE_STR) return 0;
    return o->string.len;
}

char* boblang_js_str_data(Object* o) {
    if (!o || IS_TAGGED(o) || o->type != TYPE_STR) return (char*)"";
    return o->string.data;
}

Object* boblang_js_call(const char* name, int argc, ...) {
    if (argc <= 0) {
        Object* r = boblang_js_invoke((char*)name, 0, NULL);
        return r ? r : boblang_null_new();
    }
    va_list ap;
    va_start(ap, argc);
    Object** tmp = (Object**)malloc(sizeof(Object*) * argc);
    if (!tmp) { va_end(ap); return boblang_null_new(); }
    for (int i = 0; i < argc; i++) tmp[i] = va_arg(ap, Object*);
    va_end(ap);
    Object* r = boblang_js_invoke((char*)name, argc, tmp);
    free(tmp);
    return r ? r : boblang_null_new();
}

Object* boblang_contains(Object* needle, Object* haystack) {
    if (!haystack) return MAKE_TBOOL(0);
    if (IS_TAGGED(haystack)) return MAKE_TBOOL(0);
    if (haystack->type == TYPE_LIST) {
        for (long i = 0; i < haystack->list.size; i++) {
            Object* item = haystack->list.items[i];
            if (boblang_is_truthy(beq(item, needle))) return MAKE_TBOOL(1);
        }
        return MAKE_TBOOL(0);
    }
    if (haystack->type == TYPE_DICT) {
        Object* r = boblang_dict_get(haystack, needle);
        return MAKE_TBOOL(!boblang_is_null(r));
    }
    if (haystack->type == TYPE_STR) {
        if (!needle || IS_TAGGED(needle) || needle->type != TYPE_STR) return MAKE_TBOOL(0);
        return MAKE_TBOOL(strstr(haystack->string.data, needle->string.data) != NULL);
    }
    return MAKE_TBOOL(0);
}

Object* boblang_foreign_new(int type_id, void *ptr, Object *type_name) {
    Object *obj = alloc_obj(TYPE_FOREIGN, 0);
    obj->foreign.type_id = type_id;
    obj->foreign.ptr = ptr;
    obj->foreign.type_name = type_name;
    return obj;
}

int boblang_foreign_type_id(Object *obj) {
    if (!obj || IS_TAGGED(obj) || obj->type != TYPE_FOREIGN) return -1;
    return obj->foreign.type_id;
}

int boblang_is_null(Object *obj) {
    return (obj == NULL || IS_NULL(obj));
}

Object* boblang_string_new(const char *val) {
    int len = strlen(val);
    Object *obj = alloc_obj(TYPE_STR, len + 1);
    obj->string.len = len;
    obj->string.data = (char*)obj + sizeof(Object);
    strcpy(obj->string.data, val);
    return obj;
}

Object* boblang_str_new(const char *val) {
    return boblang_string_new(val);
}

// decrypts xor encrypted constants 
Object* boblang_str_new_x(const char *enc, int len, int key) {
    char *tmp = (char*)malloc(len + 1);
    if (!tmp) { boblang_raise_error(ERR_OOM, NULL, current_line); return boblang_null_new(); }
    for (int i = 0; i < len; i++) tmp[i] = enc[i] ^ (char)key;
    tmp[len] = 0;
    Object* obj = boblang_string_new(tmp);
    free(tmp);
    return obj;
}

Object* boblang_immortal_string(const char *val) {
    int len = strlen(val);
    size_t total = sizeof(Object) + len + 1;
    void *mem = malloc(total);
    if (!mem) { boblang_raise_error(ERR_OOM, NULL, current_line); }
    Object *obj = (Object*)mem;
    obj->type = TYPE_STR;
    obj->string.len = len;
    obj->string.data = (char*)obj + sizeof(Object);
    memcpy(obj->string.data, val, len + 1);
    return obj;
}

Object* boblang_func_new(void *ptr, int arity, int required_arity, Object *name, Object *bound_self, Object *arg_names, Object *defaults, int has_vararg) {
    Object *obj = alloc_obj(TYPE_FUNC, 0);
    obj->func.ptr = ptr;
    obj->func.arity = arity;
    obj->func.required_arity = required_arity;
    obj->func.name = name;
    obj->func.bound_self = bound_self;
    obj->func.arg_names = arg_names;
    obj->func.defaults = defaults;
    obj->func.has_vararg = has_vararg;
    return obj;
}

Object* boblang_immortal_func(void *ptr, int arity, int required_arity, Object *name, Object *bound_self, Object *arg_names, Object *defaults, int has_vararg) {
    Object *obj = malloc(sizeof(Object));
    if (!obj) { boblang_raise_error(ERR_OOM, NULL, current_line); }
    obj->type = TYPE_FUNC;
    obj->func.ptr = ptr;
    obj->func.arity = arity;
    obj->func.required_arity = required_arity;
    obj->func.name = name;
    obj->func.bound_self = bound_self;
    obj->func.arg_names = arg_names;
    obj->func.defaults = defaults;
    obj->func.has_vararg = has_vararg;
    return obj;
}

Object* boblang_bigf_new(const char *decimal) {
    Object *obj = alloc_obj(TYPE_BIGF, 0);
    I256 m;
    int sc;
    if (bigf_from_str(decimal, &m, &sc) != 0) { m = i256_zero(); sc = 0; }
    obj->bigf.w[0] = m.w[0]; obj->bigf.w[1] = m.w[1]; obj->bigf.w[2] = m.w[2]; obj->bigf.w[3] = m.w[3];
    obj->bigf.scale = sc;
    return obj;
}

Object* boblang_bigi_new(const char *decimal) {
    Object *obj = alloc_obj(TYPE_BIGI, 0);
    I256 v;
    if (i256_from_str(decimal, &v) != 0) v = i256_zero();
    obj->bigi.w[0] = v.w[0]; obj->bigi.w[1] = v.w[1]; obj->bigi.w[2] = v.w[2]; obj->bigi.w[3] = v.w[3];
    return obj;
}

static Object* bigi_make(I256 v) {
    Object *o = alloc_obj(TYPE_BIGI, 0);
    o->bigi.w[0] = v.w[0]; o->bigi.w[1] = v.w[1]; o->bigi.w[2] = v.w[2]; o->bigi.w[3] = v.w[3];
    return o;
}
static Object* bigf_make(I256 m, int scale) {
    Object *o = alloc_obj(TYPE_BIGF, 0);
    o->bigf.w[0] = m.w[0]; o->bigf.w[1] = m.w[1]; o->bigf.w[2] = m.w[2]; o->bigf.w[3] = m.w[3];
    o->bigf.scale = scale;
    return o;
}

static int big_kind(Object *o) {
    if (!o || IS_TAGGED(o)) return 0;
    return o->type == TYPE_BIGI ? 1 : (o->type == TYPE_BIGF ? 2 : 0);
}

static I256 big_get_i256(Object *o) {
    if (!o) return i256_zero();
    if (IS_TINT(o)) return i256_from_i64(GET_TINT(o));
    if (IS_TFLOAT(o)) return i256_from_i64((long long)GET_TFLOAT(o));
    if (IS_TBOOL(o)) return i256_from_i64(GET_TBOOL(o));
    switch (o->type) {
        case TYPE_INT:   return i256_from_i64(o->int_val);
        case TYPE_FLOAT: return i256_from_i64((long long)o->float_val);
        case TYPE_BIGI: {
            I256 v = {{o->bigi.w[0], o->bigi.w[1], o->bigi.w[2], o->bigi.w[3]}};
            return v;
        }
        case TYPE_BIGF: {
            I256 m = {{o->bigf.w[0], o->bigf.w[1], o->bigf.w[2], o->bigf.w[3]}};
            return bigf_to_i256(m, o->bigf.scale);
        }
        default: return i256_zero();
    }
}

static void big_get_bigf(Object *o, I256 *m, int *scale) {
    if (o && !IS_TAGGED(o)) {
        if (o->type == TYPE_BIGF) {
            m->w[0] = o->bigf.w[0]; m->w[1] = o->bigf.w[1]; m->w[2] = o->bigf.w[2]; m->w[3] = o->bigf.w[3];
            *scale = o->bigf.scale;
            return;
        }
        if (o->type == TYPE_BIGI) {
            m->w[0] = o->bigi.w[0]; m->w[1] = o->bigi.w[1]; m->w[2] = o->bigi.w[2]; m->w[3] = o->bigi.w[3];
            *scale = 0;
            return;
        }
        if (o->type == TYPE_FLOAT) {
            char buf[64];
            snprintf(buf, sizeof(buf), "%.17g", o->float_val);
            if (bigf_from_str(buf, m, scale) != 0) { *m = i256_zero(); *scale = 0; }
            return;
        }
    }
    if (o && IS_TFLOAT(o)) {
        char buf[64];
        snprintf(buf, sizeof(buf), "%.17g", GET_TFLOAT(o));
        if (bigf_from_str(buf, m, scale) != 0) { *m = i256_zero(); *scale = 0; }
        return;
    }
    I256 v = big_get_i256(o);
    *m = v;
    *scale = 0;
}

Object* boblang_to_bigi(Object *obj) {
    I256 v = big_get_i256(obj);
    return bigi_make(v);
}

Object* boblang_to_bigf(Object *obj) {
    I256 m;
    int sc;
    if (obj && !IS_TAGGED(obj) && obj->type == TYPE_BIGF) {
        m.w[0] = obj->bigf.w[0]; m.w[1] = obj->bigf.w[1]; m.w[2] = obj->bigf.w[2]; m.w[3] = obj->bigf.w[3];
        sc = obj->bigf.scale;
        return bigf_make(m, sc);
    }
    if (obj && !IS_TAGGED(obj) && obj->type == TYPE_BIGI) {
        m.w[0] = obj->bigi.w[0]; m.w[1] = obj->bigi.w[1]; m.w[2] = obj->bigi.w[2]; m.w[3] = obj->bigi.w[3];
        sc = 0;
        return bigf_make(m, sc);
    }
    if (obj && (IS_TFLOAT(obj) || (!IS_TAGGED(obj) && obj->type == TYPE_FLOAT))) {
        double v = boblang_unbox_float(obj);
        char buf[64];
        snprintf(buf, sizeof(buf), "%.17g", v);
        if (bigf_from_str(buf, &m, &sc) != 0) { m = i256_zero(); sc = 0; }
        return bigf_make(m, sc);
    }
    m = big_get_i256(obj);
    return bigf_make(m, 0);
}

Object* boblang_call(Object *callable, Object **args, int argc, Object *kwargs_dict) {
    if (UNLIKELY(!callable)) boblang_raise_error(ERR_CALL_NIL, NULL, current_line);

    if (!IS_TAGGED(callable) && callable->type == TYPE_DICT) {
        Object *bases = boblang_dict_get(callable, STR_BASES);
        if (bases && !IS_TAGGED(bases) && !boblang_is_null(bases)) {
            Object *inst = boblang_dict_new();
            boblang_dict_set(inst, STR_CLASS, callable);
            Object *init = boblang_get_property(inst, STR_INIT);
        if (init && !IS_TAGGED(init) && init->type == TYPE_FUNC) {
            Object **call_args = malloc(sizeof(Object*) * (argc + 1));
            call_args[0] = inst;
            for (int i = 0; i < argc; i++) call_args[i+1] = args[i];
            Object *result = boblang_call(init, call_args, argc+1, kwargs_dict);
            free(call_args);
            return inst;
        }
            return inst;
        }
    }

    if (!IS_TAGGED(callable) && callable->type == TYPE_FUNC) {
        int expected = callable->func.arity;
        int required = callable->func.required_arity;
        int has_vararg = callable->func.has_vararg;
        void *ptr = callable->func.ptr;
        Object *bound_self = callable->func.bound_self;
        Object *arg_names = callable->func.arg_names;
        Object *defaults = callable->func.defaults;

        Object *actual_args[16];
        for (int i = 0; i < 16; i++) actual_args[i] = NULL;

        int idx = 0;
        if (bound_self) actual_args[idx++] = bound_self;

        int expected_caller = bound_self ? expected - 1 : expected;
        int required_caller = bound_self ? required - 1 : required;
        int pos_limit = has_vararg ? expected_caller - 1 : expected_caller;

        int i = 0;
        for (; i < argc && idx < (bound_self ? 1 : 0) + pos_limit; i++) actual_args[idx++] = args[i];

        if (defaults && !IS_TAGGED(defaults) && defaults->type == TYPE_LIST) {
            int default_count = defaults->list.size;
            int missing = expected_caller - (idx - (bound_self ? 1 : 0));
            if (missing > 0) {
                int default_start = expected_caller - default_count;
                for (int j = 0; j < missing; j++) {
                    int param_index = (idx - (bound_self ? 1 : 0)) + j;
                    if (param_index >= default_start) {
                        int def_idx = param_index - default_start;
                        if (def_idx < default_count) {
                            actual_args[idx++] = defaults->list.items[def_idx];
                        }
                    }
                }
            }
        }

        if (has_vararg) {
            Object *vararg_list = boblang_lister_new();
            for (; i < argc; i++) boblang_lister_append(vararg_list, args[i]);
            actual_args[(bound_self ? 1 : 0) + pos_limit] = vararg_list;
        }

        if (kwargs_dict && !IS_TAGGED(kwargs_dict) && kwargs_dict->type == TYPE_DICT &&
            arg_names && !IS_TAGGED(arg_names) && arg_names->type == TYPE_LIST) {
            for (int k = 0; k < expected_caller; k++) {
                if (k < arg_names->list.size) {
                    Object *key_str = arg_names->list.items[k];
                    Object *val = boblang_dict_get(kwargs_dict, key_str);
                    if (val && !IS_TAGGED(val) && !boblang_is_null(val))
                        actual_args[(bound_self ? 1 : 0) + k] = val;
                }
            }
        }

        switch(expected) {
            case 0: return ((Fn0)ptr)();
            case 1: return ((Fn1)ptr)(actual_args[0]);
            case 2: return ((Fn2)ptr)(actual_args[0], actual_args[1]);
            case 3: return ((Fn3)ptr)(actual_args[0], actual_args[1], actual_args[2]);
            case 4: return ((Fn4)ptr)(actual_args[0], actual_args[1], actual_args[2], actual_args[3]);
            case 5: return ((Fn5)ptr)(actual_args[0], actual_args[1], actual_args[2], actual_args[3], actual_args[4]);
            case 6: return ((Fn6)ptr)(actual_args[0], actual_args[1], actual_args[2], actual_args[3], actual_args[4], actual_args[5]);
            case 7: return ((Fn7)ptr)(actual_args[0], actual_args[1], actual_args[2], actual_args[3], actual_args[4], actual_args[5], actual_args[6]);
            case 8: return ((Fn8)ptr)(actual_args[0], actual_args[1], actual_args[2], actual_args[3], actual_args[4], actual_args[5], actual_args[6], actual_args[7]);
            default: boblang_raise_error(ERR_TOO_MANY_ARGS_MAX8, NULL, current_line);
        }
    } else if (!IS_TAGGED(callable) && (callable->type == TYPE_DICT || callable->type == TYPE_PTR)) {
        Object *call_method = boblang_dict_get(callable, STR_CALL);
        if (call_method && call_method->type == TYPE_FUNC) {
            Object *new_args[16];
            new_args[0] = callable;
            for (int i = 0; i < argc; i++) new_args[i+1] = args[i];
            return boblang_call(call_method, new_args, argc+1, kwargs_dict);
        }
        boblang_raise_error(ERR_NOT_CALLABLE, NULL, current_line);
    } else {
        boblang_raise_error(ERR_NOT_CALLABLE, NULL, current_line);
    }
    return NULL;
}


Object* boblang_lister_new() {
    Object *obj = alloc_obj(TYPE_LIST, 0);
    obj->list.size = 0;
    obj->list.capacity = 4;
    obj->list.items = calloc(obj->list.capacity, sizeof(Object*));
    if (!obj->list.items) {
        boblang_raise_error(ERR_OOM, NULL, current_line);
    }
    return obj;
}

Object* boblang_dict_new() {
    Object *obj = alloc_obj(TYPE_DICT, 0);
    obj->dict.size = 0;
    obj->dict.capacity = 8;
    obj->dict.entries = calloc(obj->dict.capacity, sizeof(*obj->dict.entries));
    if (!obj->dict.entries) {
        boblang_raise_error(ERR_OOM, NULL, current_line);
    }
    return obj;
}

int boblang_try_list_append(Object *obj, Object *value) {
    if (obj && !IS_TAGGED(obj) && obj->type == TYPE_LIST) {
        boblang_lister_append(obj, value);
        return 1;
    }
    return 0;
}

Object* boblang_int_list_new(void) {
    Object *obj = alloc_obj(TYPE_INTARRAY, 0);
    obj->intlist.size = 0;
    obj->intlist.capacity = 8;
    obj->intlist.items = malloc(sizeof(long long) * obj->intlist.capacity);
    if (!obj->intlist.items) boblang_raise_error(ERR_OOM, NULL, current_line);
    return obj;
}

void boblang_int_list_append(Object *list, long long value) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_INTARRAY) return;
    if (list->intlist.size == list->intlist.capacity) {
        list->intlist.capacity *= 2;
        long long *ni = realloc(list->intlist.items, sizeof(long long) * list->intlist.capacity);
        if (!ni) { boblang_raise_error(ERR_OOM, NULL, current_line); return; }
        list->intlist.items = ni;
    }
    list->intlist.items[list->intlist.size++] = value;
}

long long boblang_int_list_get(Object *list, long long index) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_INTARRAY) return 0;
    if (index < 0 || index >= list->intlist.size) return 0;
    return list->intlist.items[index];
}

void boblang_int_list_set(Object *list, long long index, long long value) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_INTARRAY) return;
    if (index >= 0 && index < list->intlist.size) list->intlist.items[index] = value;
}

int boblang_int_list_len(Object *list) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_INTARRAY) return 0;
    return list->intlist.size;
}

void* boblang_raw_int_new(long long n) {
    if (n <= 0) n = 1;
    return malloc((size_t)n * sizeof(long long));
}

void* boblang_raw_float_new(long long n) {
    if (n <= 0) n = 1;
    return malloc((size_t)n * sizeof(double));
}

void* boblang_raw_bool_new(long long n) {
    if (n <= 0) n = 1;
    return malloc((size_t)n * sizeof(char));
}

Object* boblang_float_list_new(void) {
    Object *obj = alloc_obj(TYPE_FLOATARRAY, 0);
    obj->floatlist.size = 0;
    obj->floatlist.capacity = 8;
    obj->floatlist.items = malloc(sizeof(double) * obj->floatlist.capacity);
    if (!obj->floatlist.items) boblang_raise_error(ERR_OOM, NULL, current_line);
    return obj;
}

void boblang_float_list_append(Object *list, double value) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_FLOATARRAY) return;
    if (list->floatlist.size == list->floatlist.capacity) {
        list->floatlist.capacity *= 2;
        double *ni = realloc(list->floatlist.items, sizeof(double) * list->floatlist.capacity);
        if (!ni) { boblang_raise_error(ERR_OOM, NULL, current_line); return; }
        list->floatlist.items = ni;
    }
    list->floatlist.items[list->floatlist.size++] = value;
}

double boblang_float_list_get(Object *list, long long index) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_FLOATARRAY) return 0.0;
    if (index < 0 || index >= list->floatlist.size) return 0.0;
    return list->floatlist.items[index];
}

void boblang_float_list_set(Object *list, long long index, double value) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_FLOATARRAY) return;
    if (index >= 0 && index < list->floatlist.size) list->floatlist.items[index] = value;
}

Object* boblang_bool_list_new(void) {
    Object *obj = alloc_obj(TYPE_BOOLARRAY, 0);
    obj->boollist.size = 0;
    obj->boollist.capacity = 16;
    obj->boollist.items = malloc(sizeof(char) * obj->boollist.capacity);
    if (!obj->boollist.items) boblang_raise_error(ERR_OOM, NULL, current_line);
    return obj;
}

void boblang_bool_list_append(Object *list, long long value) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_BOOLARRAY) return;
    if (list->boollist.size == list->boollist.capacity) {
        list->boollist.capacity *= 2;
        char *ni = realloc(list->boollist.items, sizeof(char) * list->boollist.capacity);
        if (!ni) { boblang_raise_error(ERR_OOM, NULL, current_line); return; }
        list->boollist.items = ni;
    }
    list->boollist.items[list->boollist.size++] = value ? 1 : 0;
}

long long boblang_bool_list_get(Object *list, long long index) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_BOOLARRAY) return 0;
    if (index < 0 || index >= list->boollist.size) return 0;
    return list->boollist.items[index];
}

void boblang_bool_list_set(Object *list, long long index, long long value) {
    if (!list || IS_TAGGED(list) || list->type != TYPE_BOOLARRAY) return;
    if (index >= 0 && index < list->boollist.size) list->boollist.items[index] = value ? 1 : 0;
}

void boblang_lister_append(Object *list, Object *value) {
    if (UNLIKELY(!list || IS_TAGGED(list) || list->type != TYPE_LIST)) return;
    if (UNLIKELY(list->list.size == list->list.capacity)) {
        list->list.capacity *= 2;
        Object **new_items = realloc(list->list.items,
                                     sizeof(Object*) * list->list.capacity);
        if (!new_items) {
            boblang_raise_error(ERR_OOM, NULL, current_line);
        }
        list->list.items = new_items;
    }
    list->list.items[list->list.size++] = value;
}

Object* boblang_list_get(Object *list, long long index) {
    if (UNLIKELY(!list || IS_TAGGED(list) || list->type != TYPE_LIST)) return MAKE_TBOOL(0);
    if (UNLIKELY(index < 0 || index >= list->list.size)) return MAKE_TBOOL(0);
    return list->list.items[index];
}

void boblang_list_set(Object *list, long long index, Object *value) {
    if (UNLIKELY(!list || IS_TAGGED(list) || list->type != TYPE_LIST)) return;
    if (LIKELY(index >= 0 && index < list->list.size)) {
        list->list.items[index] = value;
    }
}

long long boblang_list_len(Object *list) {
    return (list && !IS_TAGGED(list) && list->type == TYPE_LIST) ? list->list.size : 0;
}

void boblang_set_prop(Object *obj, const char *prop_name, Object *value) {
    Object *key = boblang_string_new(prop_name);
    boblang_dict_set(obj, key, value);
}

static inline uint32_t boblang_hash_obj(Object *obj) {
    if (IS_TINT(obj)) return (uint32_t)GET_TINT(obj) * 2654435761u;
    if (!IS_TAGGED(obj) && obj->type == TYPE_STR) {
        uint32_t hash = 2166136261u;
        for (char *c = obj->string.data; *c; c++) {
            hash ^= (uint8_t)(*c);
            hash *= 16777619u;
        }
        return hash;
    }
    return (uint32_t)((uintptr_t)obj >> 3);
}

void boblang_dict_set(Object *dict, Object *key, Object *value) {
    if (UNLIKELY(!dict || IS_TAGGED(dict) || dict->type != TYPE_DICT || key == NULL || value == NULL)) return;

    if (UNLIKELY(dict->dict.size * 4 >= dict->dict.capacity * 3)) {
        int old_cap = dict->dict.capacity;
        void *old_entries = dict->dict.entries;

        dict->dict.capacity *= 2;
        dict->dict.entries = calloc(dict->dict.capacity, sizeof(*dict->dict.entries));
        dict->dict.size = 0;

        struct { Object *key; Object *value; } *old_arr = old_entries;
        for (int i = 0; i < old_cap; i++) {
            if (old_arr[i].key) {
                uint32_t mask = dict->dict.capacity - 1;
                uint32_t h = boblang_hash_obj(old_arr[i].key) & mask;
                while (dict->dict.entries[h].key != NULL) h = (h + 1) & mask;
                dict->dict.entries[h].key = old_arr[i].key;
                dict->dict.entries[h].value = old_arr[i].value;
                dict->dict.size++;
            }
        }
        free(old_entries);
    }

    uint32_t mask = dict->dict.capacity - 1;
    uint32_t idx = boblang_hash_obj(key) & mask;

    while (dict->dict.entries[idx].key != NULL) {
        Object *k = dict->dict.entries[idx].key;
        if (k == key || (!IS_TAGGED(k) && !IS_TAGGED(key) && k->type == TYPE_STR && key->type == TYPE_STR && strcmp(k->string.data, key->string.data) == 0)) {
            dict->dict.entries[idx].value = value;
            return;
        }
        idx = (idx + 1) & mask;
    }

    dict->dict.entries[idx].key = key;
    dict->dict.entries[idx].value = value;
    dict->dict.size++;
}

Object* boblang_dict_get(Object *dict, Object *key) {
    if (UNLIKELY(!dict || IS_TAGGED(dict) || dict->type != TYPE_DICT || key == NULL)) return boblang_null_new();

    uint32_t mask = dict->dict.capacity - 1;
    uint32_t idx = boblang_hash_obj(key) & mask;
    uint32_t start_idx = idx;
    int probe_count = 0;

    while (dict->dict.entries[idx].key != NULL) {
        Object *k = dict->dict.entries[idx].key;
        if (k == key || (!IS_TAGGED(k) && !IS_TAGGED(key) && k->type == TYPE_STR && key->type == TYPE_STR && strcmp(k->string.data, key->string.data) == 0)) {
            return dict->dict.entries[idx].value;
        }
        idx = (idx + 1) & mask;
        probe_count++;
        if (idx == start_idx) break;
    }
    return boblang_null_new();
}

Object* boblang_get(Object *obj, Object *idx) {
    if (UNLIKELY(!obj || IS_TAGGED(obj))) {
        boblang_raise_error(ERR_INDEX_NON_INDEXABLE, NULL, current_line);
        return NULL;
    }
    if (obj->type == TYPE_LIST) {
        long long i = boblang_unbox_int(idx);
        if (UNLIKELY(i < 0 || i >= obj->list.size)) {
            boblang_raise_error(ERR_LIST_INDEX_OOB, NULL, current_line);
        }
        return obj->list.items[i];
    } else if (obj->type == TYPE_DICT) {
        return boblang_dict_get(obj, idx);
    } else {
        boblang_raise_error(ERR_INDEX_NON_INDEXABLE, NULL, current_line);
        return NULL;
    }
}

Object* boblang_get_index_int_key(Object *obj, long long key) {
    if (UNLIKELY(!obj || IS_TAGGED(obj))) {
        boblang_raise_error(ERR_INDEX_NON_INDEXABLE, NULL, current_line);
        return NULL;
    }
    if (obj->type == TYPE_LIST) {
        if (UNLIKELY(key < 0 || key >= obj->list.size)) {
            boblang_raise_error(ERR_LIST_INDEX_OOB, NULL, current_line);
        }
        return obj->list.items[key];
    } else if (obj->type == TYPE_DICT) {
        Object *key_obj = MAKE_TINT(key);
        return boblang_dict_get(obj, key_obj);
    } else if (obj->type == TYPE_STR) {
        if (UNLIKELY(key < 0 || key >= obj->string.len)) return boblang_null_new();
        char c[2] = {obj->string.data[key], 0};
        return boblang_string_new(c);
    } else {
        boblang_raise_error(ERR_INDEX_NON_INDEXABLE, NULL, current_line);
        return NULL;
    }
}

typedef struct { void** data; long long len; long long cap; } BoblangI64List;

void* boblang_i64_list_new(void) {
    BoblangI64List* l = (BoblangI64List*)malloc(sizeof(BoblangI64List));
    if (!l) { boblang_raise_error(ERR_OOM, NULL, current_line); }
    l->cap = 4;
    l->len = 0;
    l->data = (void**)calloc(l->cap, sizeof(void*));
    if (!l->data) { boblang_raise_error(ERR_OOM, NULL, current_line); }
    return l;
}

void boblang_i64_list_grow_append(void* v, long long val) {
    BoblangI64List* l = (BoblangI64List*)v;
    l->cap *= 2;
    void** nd = (void**)realloc(l->data, sizeof(void*) * l->cap);
    if (!nd) { boblang_raise_error(ERR_OOM, NULL, current_line); }
    l->data = nd;
    l->data[l->len++] = (void*)val;
}

void boblang_set_index_int_key(Object *obj, long long key, Object *value) {
    if (!obj || IS_TAGGED(obj)) return;
    if (obj->type == TYPE_LIST) {
        if (key >= 0 && key < obj->list.size) {
            obj->list.items[key] = value;
        }
    } else if (obj->type == TYPE_DICT) {
        boblang_dict_set(obj, MAKE_TINT(key), value);
    }
}

Object* boblang_slice(Object *obj, Object *start, Object *end) {
    if (UNLIKELY(!obj || IS_TAGGED(obj) || (obj->type != TYPE_LIST && obj->type != TYPE_STR))) {
        boblang_raise_error(ERR_SLICE_TARGET, NULL, current_line);
        return NULL;
    }
    int len = (obj->type == TYPE_LIST) ? obj->list.size : obj->string.len;
    int s = 0;
    if (start && !boblang_is_null(start)) {
        s = boblang_unbox_int(start);
        if (s < 0) s += len;
    }
    if (s < 0) s = 0;
    if (s > len) s = len;
    int e = len;
    if (end && !boblang_is_null(end)) {
        e = boblang_unbox_int(end);
        if (e < 0) e += len;
    }
    if (e < 0) e = 0;
    if (e > len) e = len;
    if (s > e) s = e;
    if (obj->type == TYPE_STR) {
        int new_len = e - s;
        Object *res = alloc_obj(TYPE_STR, new_len + 1);
        res->string.len = new_len;
        res->string.data = (char*)res + sizeof(Object);
        memcpy(res->string.data, obj->string.data + s, new_len);
        res->string.data[new_len] = '\0';
        return res;
    } else {
        Object *res = boblang_lister_new();
        for (int i = s; i < e; i++) {
            boblang_lister_append(res, obj->list.items[i]);
        }
        return res;
    }
}

void boblang_set_slice(Object *obj, Object *start, Object *end, Object *val) {
    if (!obj || IS_TAGGED(obj) || obj->type != TYPE_LIST) return;
    if (!val || IS_TAGGED(val) || val->type != TYPE_LIST) return;
    int len = obj->list.size;
    int s = 0;
    if (start && !boblang_is_null(start)) {
        s = boblang_unbox_int(start);
        if (s < 0) s += len;
    }
    if (s < 0) s = 0;
    if (s > len) s = len;
    int e = len;
    if (end && !boblang_is_null(end)) {
        e = boblang_unbox_int(end);
        if (e < 0) e += len;
    }
    if (e < 0) e = 0;
    if (e > len) e = len;
    if (s > e) s = e;

    int remove_count = e - s;
    int insert_count = val->list.size;
    int old_size = obj->list.size;
    int new_size = old_size - remove_count + insert_count;
    if (new_size > obj->list.capacity) {
        int new_cap = obj->list.capacity;
        while (new_cap < new_size) new_cap *= 2;
        Object **ni = realloc(obj->list.items, sizeof(Object*) * new_cap);
        if (!ni) { boblang_raise_error(ERR_OOM, NULL, current_line); return; }
        obj->list.items = ni;
        obj->list.capacity = new_cap;
    }
    if (remove_count > 0 && e < old_size)
        memmove(&obj->list.items[s], &obj->list.items[e], sizeof(Object*) * (old_size - e));
    int tail = old_size - remove_count - s;
    if (tail > 0)
        memmove(&obj->list.items[s + insert_count], &obj->list.items[s], sizeof(Object*) * tail);
    for (int i = 0; i < insert_count; i++) obj->list.items[s + i] = val->list.items[i];
    obj->list.size = new_size;
}

static void fmt_float(char *buf, size_t sz, double val) {
    snprintf(buf, sz, "%g", val);
    if (!strchr(buf, '.') && !strchr(buf, 'e') && !strchr(buf, 'E'))
        strncat(buf, ".0", sz - strlen(buf) - 1);
}

Object* boblang_to_string(Object *obj) {
    if (!obj) return boblang_string_new("nil");
    char buf[256];
    if (IS_TFLOAT(obj)) { fmt_float(buf, sizeof(buf), GET_TFLOAT(obj)); return boblang_string_new(buf); }
    if (IS_TINT(obj)) { sprintf(buf, "%lld", GET_TINT(obj)); return boblang_string_new(buf); }
    if (IS_TBOOL(obj)) { return boblang_string_new(GET_TBOOL(obj) ? "true" : "false"); }

    switch (obj->type) {
        case TYPE_FLOAT: fmt_float(buf, sizeof(buf), obj->float_val); break;
        case TYPE_STR: return obj;
        case TYPE_PTR: sprintf(buf, "<ptr %p>", obj->ptr_val); break;
        case TYPE_FUNC: sprintf(buf, "<function %p>", obj->func.ptr); break;
        case TYPE_BIGI: {
            I256 v = {{obj->bigi.w[0], obj->bigi.w[1], obj->bigi.w[2], obj->bigi.w[3]}};
            i256_to_str_buf(v, buf, sizeof(buf));
            break;
        }
        case TYPE_BIGF: {
            I256 m = {{obj->bigf.w[0], obj->bigf.w[1], obj->bigf.w[2], obj->bigf.w[3]}};
            bigf_to_str_buf(m, obj->bigf.scale, buf, sizeof(buf));
            break;
        }
        case TYPE_LIST: sprintf(buf, "<list size=%d>", obj->list.size); break;
        case TYPE_DICT: {
            Object *cls = boblang_dict_get(obj, STR_CLASS);
            if (cls && !IS_TAGGED(cls) && cls->type == TYPE_DICT) {
                Object *name = boblang_dict_get(cls, STR_NAME);
                if (name && !IS_TAGGED(name) && name->type == TYPE_STR) {
                    sprintf(buf, "<%s instance>", name->string.data);
                    break;
                }
            }
            sprintf(buf, "<dict size=%d>", obj->dict.size);
            break;
        }
        case TYPE_FOREIGN: {
            const char *tn = (obj->foreign.type_name && !IS_TAGGED(obj->foreign.type_name) && obj->foreign.type_name->type == TYPE_STR)
                ? obj->foreign.type_name->string.data : "foreign";
            sprintf(buf, "<%s>", tn);
            break;
        }
        default: sprintf(buf, "<object type=%d>", obj->type); break;
    }
    return boblang_string_new(buf);
}

Object* boblang_cast_int(Object *obj) {
    if (!obj) return MAKE_TINT(0);
    if (IS_TFLOAT(obj)) return MAKE_TINT((long long)GET_TFLOAT(obj));
    if (IS_TINT(obj)) return obj;
    if (IS_TBOOL(obj)) return MAKE_TINT(GET_TBOOL(obj));
    switch (obj->type) {
        case TYPE_FLOAT: return MAKE_TINT((long long)obj->float_val);
        case TYPE_BIGI:
        case TYPE_BIGF:  return MAKE_TINT(boblang_unbox_int(obj));
        case TYPE_STR: {
            const char *s = obj->string.data;
            if (*s == '\0') { boblang_raise_error(ERR_INT_EMPTY_STR, NULL, current_line); return MAKE_TINT(0); }
            char *end = NULL;
            long long val = strtoll(s, &end, 10);
            if (end == s || *end != '\0')
                boblang_raise_error(ERR_INT_BAD_STR, NULL, current_line);
            return MAKE_TINT(val);
        }
        default: return MAKE_TINT(0);
    }
}

Object* boblang_cast_float(Object *obj) {
    if (!obj) return boblang_float_new(0.0);
    if (IS_TFLOAT(obj)) return obj;
    if (IS_TINT(obj)) return boblang_float_new((double)GET_TINT(obj));
    if (IS_TBOOL(obj)) return boblang_float_new((double)GET_TBOOL(obj));
    if (obj->type == TYPE_STR) return boblang_float_new(atof(obj->string.data));
    if (obj->type == TYPE_FLOAT) return obj;
    if (obj->type == TYPE_BIGI || obj->type == TYPE_BIGF) return boblang_float_new(boblang_unbox_float(obj));
    return boblang_float_new(0.0);
}

Object* boblang_cast_bool(Object *obj) {
    if (!obj) return MAKE_TBOOL(0);
    if (IS_TBOOL(obj)) return obj;
    if (!IS_TAGGED(obj) && obj->type == TYPE_STR) {
        if (strcmp(obj->string.data, "true") == 0 || strcmp(obj->string.data, "1") == 0) return MAKE_TBOOL(1);
        if (strcmp(obj->string.data, "false") == 0 || strcmp(obj->string.data, "0") == 0) return MAKE_TBOOL(0);
    }
    return MAKE_TBOOL(boblang_is_truthy(obj));
}

Object* boblang_cast_str(Object *obj) {
    return boblang_to_string(obj);
}

Object* boblang_type(Object *obj) {
    if (!obj) return boblang_string_new("nil");
    if (IS_TFLOAT(obj)) return boblang_string_new("float");
    if (IS_TINT(obj)) return boblang_string_new("int");
    if (IS_TBOOL(obj)) return boblang_string_new("bool");

    if (obj->type == TYPE_DICT) {
        Object *cls = boblang_dict_get(obj, STR_CLASS);
        if (cls && !IS_TAGGED(cls) && cls->type == TYPE_DICT) {
            Object *name = boblang_dict_get(cls, STR_NAME);
            if (name && !IS_TAGGED(name) && name->type == TYPE_STR) return name;
        }
        return boblang_string_new("dict");
    }
    switch (obj->type) {
        case TYPE_FLOAT: return boblang_string_new("float");
        case TYPE_STR: return boblang_string_new("str");
        case TYPE_LIST: return boblang_string_new("list");
        case TYPE_FUNC: return boblang_string_new("function");
        case TYPE_BIGI: return boblang_string_new("bigi");
        case TYPE_BIGF: return boblang_string_new("bigf");
        case TYPE_FOREIGN: return obj->foreign.type_name;
        default: return boblang_string_new("unknown");
    }
}

int boblang_list_size_raw(Object *obj) {
    if (UNLIKELY(!obj || IS_TAGGED(obj) || obj->type != TYPE_LIST)) return 0;
    return obj->list.size;
}

Object** boblang_list_items(Object *obj) {
    if (UNLIKELY(!obj || IS_TAGGED(obj) || obj->type != TYPE_LIST)) return NULL;
    return obj->list.items;
}

char* boblang_to_string_c(Object* obj) {
    if (!obj || IS_NULL(obj)) return "nil";
    if (!IS_TAGGED(obj) && obj->type == TYPE_STR) return obj->string.data;
    if (!IS_TAGGED(obj) && obj->type == TYPE_FOREIGN) {
        if (obj->foreign.type_name && !IS_TAGGED(obj->foreign.type_name) && obj->foreign.type_name->type == TYPE_STR) {
            return obj->foreign.type_name->string.data;
        }
        return "foreign";
    }
    Object* s = boblang_to_string(obj);
    return s->string.data;
}

Object* boblang_range(Object *a, Object *b, Object *c) {
    long long start = 0, end = 0, step = 1;
    if (b == NULL) {
        end = boblang_unbox_int(a) - 1;
    } else {
        start = boblang_unbox_int(a);
        end = boblang_unbox_int(b);
        if (c != NULL) step = boblang_unbox_int(c);
    }

    Object *list = boblang_lister_new();
    if (step > 0) {
        for (long long i = start; i <= end; i += step) {
            boblang_lister_append(list, MAKE_TINT(i));
        }
    } else if (step < 0) {
        for (long long i = start; i >= end; i += step) {
            boblang_lister_append(list, MAKE_TINT(i));
        }
    }
    return list;
}

Object* boblang_len(Object *obj) {
    if (UNLIKELY(!obj || IS_TAGGED(obj))) return MAKE_TINT(0);
    if (obj->type == TYPE_LIST) return MAKE_TINT(obj->list.size);
    if (obj->type == TYPE_INTARRAY) return MAKE_TINT(obj->intlist.size);
    if (obj->type == TYPE_FLOATARRAY) return MAKE_TINT(obj->floatlist.size);
    if (obj->type == TYPE_BOOLARRAY) return MAKE_TINT(obj->boollist.size);
    if (obj->type == TYPE_DICT) return MAKE_TINT(obj->dict.size);
    if (obj->type == TYPE_STR) return MAKE_TINT(obj->string.len);
    return MAKE_TINT(0);
}

static int strcaseeq(const char *a, const char *b) {
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
        a++;
        b++;
    }
    return *a == *b;
}

void boblang_assert_type(Object *obj, char *expected, char *var_name, int line) {
    if (!obj) return;
    if (strcmp(expected, "any") == 0) return;

    /* expected "list[T]": a boxed list is accepted if every element passes the
       inner type check (nested generics recurse back into this function). */
    if (strncmp(expected, "list[", 5) == 0 && !IS_TAGGED(obj) && obj->type == TYPE_LIST) {
        const char *close = strrchr(expected, ']');
        if (close && close > expected + 5) {
            int elen = (int)(close - (expected + 5));
            char elem_buf[128];
            if (elen >= (int)sizeof(elem_buf)) elen = (int)sizeof(elem_buf) - 1;
            memcpy(elem_buf, expected + 5, elen);
            elem_buf[elen] = '\0';
            for (int i = 0; i < (int)obj->list.size; i++) {
                boblang_assert_type(obj->list.items[i], elem_buf, var_name, line);
            }
            return;
        }
    }

    const char *actual = "unknown";
    if (IS_TINT(obj)) actual = "int";
    else if (IS_TBOOL(obj)) actual = "bool";
    else if (IS_TFLOAT(obj)) actual = "float";
    else switch(obj->type) {
        case TYPE_STR:   actual = "str";   break;
        case TYPE_FLOAT: actual = "float"; break;
        case TYPE_LIST:  actual = "list";  break;
        case TYPE_INTARRAY:   actual = "list[int]";   break;
        case TYPE_FLOATARRAY: actual = "list[float]"; break;
        case TYPE_BOOLARRAY:  actual = "list[bool]";  break;
        case TYPE_DICT: {
            Object *cls = boblang_dict_get(obj, STR_CLASS);
            if (cls && !IS_TAGGED(cls) && cls->type == TYPE_DICT) {
                Object *name = boblang_dict_get(cls, STR_NAME);
                if (name && !IS_TAGGED(name) && name->type == TYPE_STR) {
                    if (strcaseeq(name->string.data, expected)) return;
                }
            }
            actual = "dict";
            break;
        }
        case TYPE_FUNC:  actual = "func";  break;
        case TYPE_BIGI:  actual = "bigi";  break;
        case TYPE_BIGF:  actual = "bigf";  break;
        case TYPE_PTR:   actual = "ptr";   break;
        case TYPE_FOREIGN: actual = "foreign"; break;
        default: break;
    }
    if (strcmp(actual, expected) == 0) return;
    if (strcmp(expected, "float") == 0 && strcmp(actual, "int") == 0)
        return;
    if (strcmp(expected, "list") == 0 &&
        (obj->type == TYPE_LIST || obj->type == TYPE_INTARRAY ||
         obj->type == TYPE_FLOATARRAY || obj->type == TYPE_BOOLARRAY))
        return;
    /* big number coercions: allow int/float <-> bigi/bigf */
    if ((strcmp(expected, "int") == 0 || strcmp(expected, "float") == 0) &&
        (strcmp(actual, "bigi") == 0 || strcmp(actual, "bigf") == 0))
        return;
    if ((strcmp(expected, "bigi") == 0 || strcmp(expected, "bigf") == 0) &&
        (strcmp(actual, "int") == 0 || strcmp(actual, "float") == 0 ||
         strcmp(actual, "bigi") == 0 || strcmp(actual, "bigf") == 0))
        return;
    char msg[256];
    snprintf(msg, 256, "Type Mismatch: variable '%s' expected %s, got %s", var_name, expected, actual);
    boblang_raise_error(ERR_TYPE_ASSERT_FAILED, msg, line);
}

Object* badd(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) return MAKE_TINT(GET_TINT(a) + GET_TINT(b));

    if (big_kind(a) || big_kind(b)) {
        if (big_kind(a) == 2 || big_kind(b) == 2) {
            I256 am, bm;
            int as, bs;
            big_get_bigf(a, &am, &as);
            big_get_bigf(b, &bm, &bs);
            I256 rm; int rs;
            bigf_add(am, as, bm, bs, &rm, &rs);
            return bigf_make(rm, rs);
        }
        return bigi_make(i256_add(big_get_i256(a), big_get_i256(b)));
    }

    if ((!IS_TAGGED(a) && a->type == TYPE_STR) || (!IS_TAGGED(b) && b->type == TYPE_STR)) {
        Object *sa = boblang_to_string(a);
        Object *sb = boblang_to_string(b);
        int len = sa->string.len + sb->string.len;
        char *tmp = malloc(len + 1);
        strcpy(tmp, sa->string.data);
        strcat(tmp, sb->string.data);
        Object *result = boblang_string_new(tmp);
        free(tmp);
        return result;
    }

    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(av + bv);
}

Object* bsub(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) return MAKE_TINT(GET_TINT(a) - GET_TINT(b));

    if (big_kind(a) || big_kind(b)) {
        if (big_kind(a) == 2 || big_kind(b) == 2) {
            I256 am, bm;
            int as, bs;
            big_get_bigf(a, &am, &as);
            big_get_bigf(b, &bm, &bs);
            I256 rm; int rs;
            bigf_sub(am, as, bm, bs, &rm, &rs);
            return bigf_make(rm, rs);
        }
        return bigi_make(i256_sub(big_get_i256(a), big_get_i256(b)));
    }

    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(av - bv);
}

Object* bmul(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) return MAKE_TINT(GET_TINT(a) * GET_TINT(b));

    if (big_kind(a) || big_kind(b)) {
        if (big_kind(a) == 2 || big_kind(b) == 2) {
            I256 am, bm;
            int as, bs;
            big_get_bigf(a, &am, &as);
            big_get_bigf(b, &bm, &bs);
            I256 rm; int rs;
            bigf_mul(am, as, bm, bs, &rm, &rs);
            return bigf_make(rm, rs);
        }
        return bigi_make(i256_mul(big_get_i256(a), big_get_i256(b)));
    }

    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(av * bv);
}

Object* bdiv(Object *a, Object *b) {
    if (big_kind(a) || big_kind(b)) {
        I256 am, bm;
        int as, bs;
        big_get_bigf(a, &am, &as);
        big_get_bigf(b, &bm, &bs);
        I256 rm; int rs;
        bigf_div(am, as, bm, bs, &rm, &rs);
        return bigf_make(rm, rs);
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(av / bv);
}

Object* bpow(Object *a, Object *b) {
    if (big_kind(a) || big_kind(b)) {
        double av = boblang_unbox_float(a);
        double bv = boblang_unbox_float(b);
        return boblang_to_bigf(boblang_float_new(pow(av, bv)));
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(pow(av, bv));
}

Object* bmod(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) {
        long long bv = GET_TINT(b);
        if (UNLIKELY(bv == 0)) boblang_raise_error(ERR_MODULO_ZERO, NULL, current_line);
        return MAKE_TINT(GET_TINT(a) % bv);
    }
    if (big_kind(a) || big_kind(b)) {
        I256 bv = big_get_i256(b);
        if (i256_is_zero(bv)) boblang_raise_error(ERR_MODULO_ZERO, NULL, current_line);
        I256 rem;
        i256_sdiv(big_get_i256(a), bv, &rem);
        return bigi_make(rem);
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    if (UNLIKELY(bv == 0.0)) boblang_raise_error(ERR_MODULO_ZERO, NULL, current_line);
    return boblang_float_new(fmod(av, bv));
}

Object* bidiv(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) {
        long long bv = GET_TINT(b);
        if (UNLIKELY(bv == 0)) boblang_raise_error(ERR_INT_DIV_ZERO, NULL, current_line);
        return MAKE_TINT(GET_TINT(a) / bv);
    }
    if (big_kind(a) || big_kind(b)) {
        I256 bv = big_get_i256(b);
        if (i256_is_zero(bv)) boblang_raise_error(ERR_INT_DIV_ZERO, NULL, current_line);
        return bigi_make(i256_sdiv(big_get_i256(a), bv, NULL));
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    if (UNLIKELY(bv == 0.0)) boblang_raise_error(ERR_INT_DIV_ZERO, NULL, current_line);
    return MAKE_TINT((long long)(av / bv));
}

Object* beq(Object *a, Object *b) {
    if (a == b) return MAKE_TBOOL(1);
    if (big_kind(a) || big_kind(b)) {
        if (big_kind(a) == 2 || big_kind(b) == 2) {
            I256 am, bm;
            int as, bs;
            big_get_bigf(a, &am, &as);
            big_get_bigf(b, &bm, &bs);
            return MAKE_TBOOL(bigf_cmp(am, as, bm, bs) == 0);
        }
        return MAKE_TBOOL(i256_cmp(big_get_i256(a), big_get_i256(b)) == 0);
    }
    if (IS_TFLOAT(a) || IS_TFLOAT(b)) {
        if (!IS_TFLOAT(a) || !IS_TFLOAT(b)) return MAKE_TBOOL(0);
        return MAKE_TBOOL(GET_TFLOAT(a) == GET_TFLOAT(b));
    }
    if (IS_TAGGED(a) || IS_TAGGED(b)) return MAKE_TBOOL(0);
    if (a->type != b->type) return MAKE_TBOOL(0);
    switch (a->type) {
        case TYPE_FLOAT:return MAKE_TBOOL(a->float_val == b->float_val);
        case TYPE_STR:  return MAKE_TBOOL(strcmp(a->string.data, b->string.data) == 0);
        case TYPE_PTR:  return MAKE_TBOOL(a->ptr_val == b->ptr_val);
        default:        return MAKE_TBOOL(0);
    }
}

Object* bneq(Object *a, Object *b) {
    return MAKE_TBOOL(!boblang_is_truthy(beq(a, b)));
}

Object* bgt(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) return MAKE_TBOOL(GET_TINT(a) > GET_TINT(b));
    if (big_kind(a) || big_kind(b)) {
        if (big_kind(a) == 2 || big_kind(b) == 2) {
            I256 am, bm;
            int as, bs;
            big_get_bigf(a, &am, &as);
            big_get_bigf(b, &bm, &bs);
            return MAKE_TBOOL(bigf_cmp(am, as, bm, bs) > 0);
        }
        return MAKE_TBOOL(i256_cmp(big_get_i256(a), big_get_i256(b)) > 0);
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return MAKE_TBOOL(av > bv);
}

Object* blt(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) return MAKE_TBOOL(GET_TINT(a) < GET_TINT(b));
    if (big_kind(a) || big_kind(b)) {
        if (big_kind(a) == 2 || big_kind(b) == 2) {
            I256 am, bm;
            int as, bs;
            big_get_bigf(a, &am, &as);
            big_get_bigf(b, &bm, &bs);
            return MAKE_TBOOL(bigf_cmp(am, as, bm, bs) < 0);
        }
        return MAKE_TBOOL(i256_cmp(big_get_i256(a), big_get_i256(b)) < 0);
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return MAKE_TBOOL(av < bv);
}

Object* bge(Object *a, Object *b) {
    return MAKE_TBOOL(boblang_is_truthy(bgt(a, b)) || boblang_is_truthy(beq(a, b)));
}

Object* ble(Object *a, Object *b) {
    return MAKE_TBOOL(boblang_is_truthy(blt(a, b)) || boblang_is_truthy(beq(a, b)));
}

Object* boblang_and(Object *a, Object *b) {
    return MAKE_TBOOL(boblang_is_truthy(a) && boblang_is_truthy(b));
}

Object* boblang_or(Object *a, Object *b) {
    return MAKE_TBOOL(boblang_is_truthy(a) || boblang_is_truthy(b));
}

Object* boblang_not(Object *a) {
    return MAKE_TBOOL(!boblang_is_truthy(a));
}

int boblang_is_truthy(Object *obj) {
    if (UNLIKELY(!obj || IS_NULL(obj))) return 0;
    if (LIKELY(IS_TINT(obj))) return GET_TINT(obj) != 0;
    if (IS_TBOOL(obj)) return GET_TBOOL(obj);
    if (IS_TFLOAT(obj)) return GET_TFLOAT(obj) != 0.0;

    switch (obj->type) {
        case TYPE_FLOAT: return obj->float_val != 0.0;
        case TYPE_STR:   return obj->string.len > 0;
        case TYPE_LIST:  return obj->list.size > 0;
        case TYPE_DICT:  return obj->dict.size > 0;
        case TYPE_PTR:   return obj->ptr_val != NULL;
        case TYPE_BIGI: {
            I256 v = {{obj->bigi.w[0], obj->bigi.w[1], obj->bigi.w[2], obj->bigi.w[3]}};
            return !i256_is_zero(v);
        }
        case TYPE_BIGF: {
            I256 m = {{obj->bigf.w[0], obj->bigf.w[1], obj->bigf.w[2], obj->bigf.w[3]}};
            return !i256_is_zero(m);
        }
        default:         return 0;
    }
}

void boblang_print(Object *obj) {
    if (!obj || IS_NULL(obj)) { printf("nil"); return; }
    char buf[128];
    if (IS_TFLOAT(obj)) { fmt_float(buf, sizeof(buf), GET_TFLOAT(obj)); printf("%s", buf); return; }
    if (IS_TINT(obj)) { printf("%lld", GET_TINT(obj)); return; }
    if (IS_TBOOL(obj)) { printf(GET_TBOOL(obj) ? "true" : "false"); return; }
    switch (obj->type) {
        case TYPE_FLOAT: fmt_float(buf, sizeof(buf), obj->float_val); printf("%s", buf); break;
        case TYPE_STR:   printf("%s", obj->string.data); break;
        case TYPE_BIGF:
        case TYPE_BIGI: {
            Object *s = boblang_to_string(obj);
            printf("%s", s->string.data);
            break;
        }
        case TYPE_PTR:   printf("<ptr:%p>", obj->ptr_val); break;
        case TYPE_LIST:
            printf("[");
            for (int i = 0; i < obj->list.size; i++) {
                if (i > 0) printf(", ");
                boblang_print(obj->list.items[i]);
            }
            printf("]");
            break;
        case TYPE_INTARRAY:
            printf("[");
            for (int i = 0; i < obj->intlist.size; i++) {
                if (i > 0) printf(", ");
                printf("%lld", obj->intlist.items[i]);
            }
            printf("]");
            break;
        case TYPE_FLOATARRAY:
            printf("[");
            for (int i = 0; i < obj->floatlist.size; i++) {
                if (i > 0) printf(", ");
                char buf[64];
                fmt_float(buf, sizeof(buf), obj->floatlist.items[i]);
                printf("%s", buf);
            }
            printf("]");
            break;
        case TYPE_BOOLARRAY:
            printf("[");
            for (int i = 0; i < obj->boollist.size; i++) {
                if (i > 0) printf(", ");
                printf(obj->boollist.items[i] ? "true" : "false");
            }
            printf("]");
            break;
        case TYPE_DICT:
            printf("{");
            int first = 1;
            for (int i = 0; i < obj->dict.capacity; i++) {
                if (obj->dict.entries[i].key != NULL) {
                    if (!first) printf(", ");
                    boblang_print(obj->dict.entries[i].key);
                    printf(": ");
                    boblang_print(obj->dict.entries[i].value);
                    first = 0;
                }
            }
            printf("}");
            break;
        default: printf("<?>");
    }
}

Object* boblang_input(Object *prompt) {
    if (prompt && prompt->type != TYPE_PTR) {
        boblang_print(prompt);
        fflush(stdout);
    }
    char buf[1024];
    if (!fgets(buf, sizeof(buf), stdin)) {
        buf[0] = '\0';
    }
    int len = strlen(buf);
    if (len > 0 && buf[len-1] == '\n') {
        buf[len-1] = '\0';
    }
     return boblang_string_new(buf);
}

Object* boblang_get_property(Object *obj, Object *key) {
    if (!obj || IS_TAGGED(obj) || key == NULL) return boblang_null_new();

    if (obj->type == TYPE_FOREIGN) {
        if (!IS_TAGGED(key) && key->type == TYPE_STR) {
            return __boblang_rust_get_property(obj->foreign.type_id, obj->foreign.ptr, key->string.data);
        }
        return boblang_null_new();
    }

    if (!IS_TAGGED(key) && key->type == TYPE_STR) {
        const char *ks = key->string.data;

        if (strcmp(ks, "length") == 0) {
            if (obj->type == TYPE_LIST) return MAKE_TINT(obj->list.size);
            if (obj->type == TYPE_DICT) return MAKE_TINT(obj->dict.size);
            if (obj->type == TYPE_STR) return MAKE_TINT(obj->string.len);
        }

        if (obj->type == TYPE_LIST) {
            if (strcmp(ks, "append") == 0)  return FUNC_LIST_APPEND;
            if (strcmp(ks, "pop") == 0)     return FUNC_LIST_POP;
            if (strcmp(ks, "clear") == 0)   return FUNC_LIST_CLEAR;
            if (strcmp(ks, "reverse") == 0) return FUNC_LIST_REVERSE;
            if (strcmp(ks, "sort") == 0)    return FUNC_LIST_SORT;
            if (strcmp(ks, "map") == 0)     return FUNC_LIST_MAP;
            if (strcmp(ks, "filter") == 0)  return FUNC_LIST_FILTER;
            if (strcmp(ks, "reduce") == 0)  return FUNC_LIST_REDUCE;
        }
    }

    if (obj->type == TYPE_FUNC) {
        if (key == STR_PROPS || (!IS_TAGGED(key) && key->type == TYPE_STR && strcmp(key->string.data, "props") == 0)) {
            Object *d = boblang_dict_new();
            Object *name_str = obj->func.name ? obj->func.name : boblang_string_new("");
            Object *name_key = boblang_immortal_string("name");
            boblang_dict_set(d, name_key, name_str);
            Object *arity_key = boblang_immortal_string("arity");
            boblang_dict_set(d, arity_key, MAKE_TINT(obj->func.arity));
            Object *req_key = boblang_immortal_string("required");
            boblang_dict_set(d, req_key, MAKE_TINT(obj->func.required_arity));
            return d;
        }
        return boblang_null_new();
    }

    if (obj->type == TYPE_DICT) {
        int is_class_meta_key = (key == STR_CLASS || (!IS_TAGGED(key) && key->type == TYPE_STR && strcmp(key->string.data, "__class__") == 0));
        if (is_class_meta_key) {
            return boblang_dict_get(obj, STR_CLASS);
        }

        Object *cls = boblang_dict_get(obj, STR_CLASS);
        if (cls && !IS_TAGGED(cls) && cls->type == TYPE_DICT) {
            int is_special_meta = (key == STR_INIT || key == STR_NAME || key == STR_BASES ||
                (!IS_TAGGED(key) && key->type == TYPE_STR &&
                 (strcmp(key->string.data, "__init__") == 0 || strcmp(key->string.data, "__name__") == 0 || strcmp(key->string.data, "__bases__") == 0)));

            if (is_special_meta) {
                Object *meta_val = boblang_dict_get(cls, key);
                return meta_val ? meta_val : boblang_null_new();
            }

            Object *val = boblang_dict_get(obj, key);
            if (val && !boblang_is_null(val)) return val;

            val = boblang_dict_get(cls, key);
            if (val && !boblang_is_null(val)) return val;

            Object *bases = boblang_dict_get(cls, STR_BASES);
            if (bases && !IS_TAGGED(bases) && bases->type == TYPE_LIST) {
                for (int i = 0; i < bases->list.size; i++) {
                    Object *base = bases->list.items[i];
                    if (base && !IS_TAGGED(base) && base->type == TYPE_DICT) {
                        Object *val2 = boblang_get_property(base, key);
                        if (val2 && !boblang_is_null(val2)) return val2;
                    }
                }
            }

            Object *fallback = boblang_dict_get(obj, key);
            return fallback ? fallback : boblang_null_new();
        } else {
            Object *val = boblang_dict_get(obj, key);
            return val ? val : boblang_null_new();
        }
    }
    return boblang_null_new();
}

void boblang_set_property(Object *obj, Object *key, Object *value) {
    if (!obj || IS_TAGGED(obj) || key == NULL) return;
    if (obj->type == TYPE_FOREIGN) {
        return;
    }
    if (obj->type == TYPE_DICT) {
        boblang_dict_set(obj, key, value);
    }
}

Object* boblang_get_index(Object *obj, Object *idx) {
    if (!obj || IS_TAGGED(obj)) return boblang_null_new();
    if (obj->type == TYPE_LIST) {
        long long i = boblang_unbox_int(idx);
        if (i < 0 || i >= obj->list.size) return boblang_null_new();
        return obj->list.items[i];
    } else if (obj->type == TYPE_DICT) {
        return boblang_dict_get(obj, idx);
    } else if (obj->type == TYPE_STR) {
        long long i = boblang_unbox_int(idx);
        if (i < 0 || i >= obj->string.len) return boblang_null_new();
        char c[2] = {obj->string.data[i], 0};
        return boblang_string_new(c);
    }
    return boblang_null_new();
}

void boblang_set_index(Object *obj, Object *idx, Object *value) {
    if (!obj || IS_TAGGED(obj)) return;
    if (obj->type == TYPE_LIST) {
        long long i = boblang_unbox_int(idx);
        if (i >= 0 && i < obj->list.size) {
            obj->list.items[i] = value;
        }
    } else if (obj->type == TYPE_DICT) {
        boblang_dict_set(obj, idx, value);
    }
}

Object* boblang_runtime_call_method(Object *instance, Object *method_name, int argc, Object **args) {
    if (instance && !IS_TAGGED(instance) && instance->type == TYPE_FOREIGN) {
        if (!IS_TAGGED(method_name) && method_name->type == TYPE_STR) {
            return __boblang_rust_call_method(instance->foreign.type_id, instance->foreign.ptr, method_name->string.data, argc, args);
        }
        boblang_raise_error(ERR_METHOD_NAME_NOT_STR, NULL, current_line);
        return NULL;
    }
    Object *method = boblang_get_property(instance, method_name);
    if (!method || IS_TAGGED(method) || method->type != TYPE_FUNC) {
        const char *name = boblang_unbox_str(method_name);
        char msg[256];
        snprintf(msg, sizeof(msg), "Method '%s' not found or not callable", name);
        boblang_raise_error(ERR_METHOD_NOT_FOUND, msg, current_line);
        return NULL;
    }
    Object **call_args = malloc(sizeof(Object*) * (argc + 1));
    call_args[0] = instance;
    for (int i = 0; i < argc; i++) call_args[i+1] = args[i];
    Object *result = boblang_call(method, call_args, argc+1, NULL);
    free(call_args);
    return result;
}

Object* boblang_runtime_call_method_va(Object *instance, Object *method_name, int argc, ...) {
    va_list va;
    va_start(va, argc);
    Object **args = malloc(sizeof(Object*) * argc);
    for (int i = 0; i < argc; i++) args[i] = va_arg(va, Object*);
    va_end(va);
    Object *result = boblang_runtime_call_method(instance, method_name, argc, args);
    free(args);
    return result;
}

Object* boblang_class_new(Object *name, Object *bases, Object *methods) {
    Object *cls = boblang_dict_new();
    boblang_dict_set(cls, STR_NAME, name);
    boblang_dict_set(cls, STR_BASES, bases ? bases : boblang_lister_new());
    if (methods && !IS_TAGGED(methods) && methods->type == TYPE_DICT) {
        for (int i = 0; i < methods->dict.capacity; i++) {
            if (methods->dict.entries[i].key) {
                boblang_dict_set(cls, methods->dict.entries[i].key, methods->dict.entries[i].value);
            }
        }
    }
    return cls;
}

Object* boblang_instance_new(Object *cls) {
    Object *inst = boblang_dict_new();
    boblang_dict_set(inst, STR_CLASS, cls);
    return inst;
}


Object* bob_print(Object *obj) {
    boblang_print(obj);
    return boblang_int_new(0);
}

Object* bob_input(Object *prompt) {
    return boblang_input(prompt);
}

Object* bob_int(Object *obj) {
    return boblang_cast_int(obj);
}

Object* bob_float(Object *obj) {
    return boblang_cast_float(obj);
}

Object* bob_str(Object *obj) {
    return boblang_cast_str(obj);
}

Object* bob_bool(Object *obj) {
    return boblang_cast_bool(obj);
}

Object* bob_type(Object *obj) {
    return boblang_type(obj);
}

Object* bob_len(Object *obj) {
    return boblang_len(obj);
}

Object* bob_range(Object *a, Object *b, Object *c) {
    return boblang_range(a, b, c);
}

Object* bob_min(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) {
        return MAKE_TINT(GET_TINT(a) < GET_TINT(b) ? GET_TINT(a) : GET_TINT(b));
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(av < bv ? av : bv);
}

Object* bob_max(Object *a, Object *b) {
    if (LIKELY(IS_TINT(a) && IS_TINT(b))) {
        return MAKE_TINT(GET_TINT(a) > GET_TINT(b) ? GET_TINT(a) : GET_TINT(b));
    }
    double av = boblang_unbox_float(a);
    double bv = boblang_unbox_float(b);
    return boblang_float_new(av > bv ? av : bv);
}

Object* bob_clamp(Object *val, Object *lo, Object *hi) {
    Object* tmp = bob_max(val, lo);
    return bob_min(tmp, hi);
}

Object* bob_ascii(Object *obj) {
    const char *s = boblang_unbox_str(obj);
    if (s && s[0]) return MAKE_TINT((long long)(unsigned char)s[0]);
    return MAKE_TINT(0);
}

Object* bob_chr(Object *obj) {
    long long code = boblang_unbox_int(obj);
    char buf[2] = {(char)code, 0};
    return boblang_string_new(buf);
}

static int sort_class(Object *obj) {
    if (!obj) return 3;
    if (IS_TINT(obj) || IS_TFLOAT(obj) || IS_TBOOL(obj)) return 0;
    if (!IS_TAGGED(obj)) {
        switch (obj->type) {
            case TYPE_INT: case TYPE_FLOAT: case TYPE_BOOL: return 0;
            case TYPE_LIST: return 1;
            case TYPE_STR: return 2;
            default: return 3;
        }
    }
    return 3;
}

static double sort_numeric(Object *obj) {
    if (!obj) return 0.0;
    if (IS_TINT(obj)) return (double)GET_TINT(obj);
    if (IS_TFLOAT(obj)) return GET_TFLOAT(obj);
    if (IS_TBOOL(obj)) return (double)GET_TBOOL(obj);
    if (!IS_TAGGED(obj)) {
        switch (obj->type) {
            case TYPE_INT: return (double)obj->int_val;
            case TYPE_FLOAT: return obj->float_val;
            case TYPE_BOOL: return (double)obj->bool_val;
            default: return 0.0;
        }
    }
    return 0.0;
}

static int sort_compare(Object *a, Object *b) {
    int ca = sort_class(a), cb = sort_class(b);
    if (ca != cb) return ca - cb;
    switch (ca) {
        case 0: {
            double da = sort_numeric(a), db = sort_numeric(b);
            if (da < db) return -1;
            if (da > db) return 1;
            return 0;
        }
        case 1: {
            if (!a || IS_TAGGED(a) || a->type != TYPE_LIST) return !b || IS_TAGGED(b) || b->type != TYPE_LIST ? 0 : -1;
            if (!b || IS_TAGGED(b) || b->type != TYPE_LIST) return 1;
            if (a->list.size == 0 && b->list.size == 0) return 0;
            if (a->list.size == 0) return -1;
            if (b->list.size == 0) return 1;
            return sort_compare(a->list.items[0], b->list.items[0]);
        }
        case 2: {
            const char *sa = "", *sb = "";
            if (a && !IS_TAGGED(a) && a->type == TYPE_STR) sa = a->string.data;
            if (b && !IS_TAGGED(b) && b->type == TYPE_STR) sb = b->string.data;
            return strcmp(sa, sb);
        }
        default: return 0;
    }
}

static void quicksort(Object **items, int low, int high) {
    if (low >= high) return;
    int i = low - 1, j = high + 1;
    Object *pivot = items[(low + high) / 2];
    while (1) {
        do { i++; } while (i <= high && sort_compare(pivot, items[i]) > 0);
        do { j--; } while (j >= low && sort_compare(items[j], pivot) > 0);
        if (i >= j) break;
        Object *tmp = items[i];
        items[i] = items[j];
        items[j] = tmp;
    }
    quicksort(items, low, j);
    quicksort(items, j + 1, high);
}

Object* boblang_list_sort_impl(Object *self) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) {
        boblang_raise_error(ERR_SORT_NEEDS_LIST, NULL, current_line);
        return NULL;
    }
    int n = self->list.size;
    if (n > 1) quicksort(self->list.items, 0, n - 1);
    return self;
}

Object* boblang_list_append_impl(Object *self, Object *value) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) {
        boblang_raise_error(ERR_APPEND_NEEDS_LIST, NULL, current_line);
        return NULL;
    }
    boblang_lister_append(self, value);
    return self;
}

Object* boblang_list_pop_impl(Object *self) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) {
        boblang_raise_error(ERR_POP_NEEDS_LIST, NULL, current_line);
        return NULL;
    }
    if (UNLIKELY(self->list.size == 0)) {
        boblang_raise_error(ERR_POP_EMPTY_LIST, NULL, current_line);
        return NULL;
    }
    self->list.size--;
    Object *value = self->list.items[self->list.size];
    self->list.items[self->list.size] = NULL;
    return value;
}

Object* boblang_list_clear_impl(Object *self) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) {
        boblang_raise_error(ERR_CLEAR_NEEDS_LIST, NULL, current_line);
        return NULL;
    }
    self->list.size = 0;
    return self;
}

Object* boblang_list_reverse_impl(Object *self) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) {
        boblang_raise_error(ERR_REVERSE_NEEDS_LIST, NULL, current_line);
        return NULL;
    }
    int n = self->list.size;
    for (int i = 0; i < n / 2; i++) {
        int j = n - 1 - i;
        Object *tmp = self->list.items[i];
        self->list.items[i] = self->list.items[j];
        self->list.items[j] = tmp;
    }
    return self;
}

Object* boblang_list_map_impl(Object *self, Object *func) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) return boblang_null_new();
    Object *res = boblang_lister_new();
    for (long i = 0; i < self->list.size; i++) {
        Object *args[1] = { self->list.items[i] };
        Object *r = boblang_call(func, args, 1, NULL);
        boblang_lister_append(res, r);
    }
    return res;
}

Object* boblang_list_filter_impl(Object *self, Object *func) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) return boblang_null_new();
    Object *res = boblang_lister_new();
    for (long i = 0; i < self->list.size; i++) {
        Object *item = self->list.items[i];
        Object *args[1] = { item };
        Object *r = boblang_call(func, args, 1, NULL);
        if (boblang_is_truthy(r)) boblang_lister_append(res, item);
    }
    return res;
}

Object* boblang_list_reduce_impl(Object *self, Object *func) {
    if (UNLIKELY(!self || IS_TAGGED(self) || self->type != TYPE_LIST)) return boblang_null_new();
    long n = self->list.size;
    if (n == 0) return boblang_null_new();
    Object *acc = self->list.items[0];
    for (long i = 1; i < n; i++) {
        Object *args[2] = { acc, self->list.items[i] };
        acc = boblang_call(func, args, 2, NULL);
    }
    return acc;
}

Object* bob_get_args(void) {
    Object *list = boblang_lister_new();
    for (int i = 0; i < boblang_cli_argc; i++) {
        boblang_lister_append(list, boblang_string_new(boblang_cli_argv[i]));
    }
    return list;
}