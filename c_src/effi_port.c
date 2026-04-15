/*
 * effi_port.c — Safe-mode port executable for Erlang CFFI.
 *
 * Runs as a separate OS process. Communicates with the Erlang VM via
 * stdin/stdout using 4-byte big-endian length-prefixed binary frames.
 *
 * Request  wire format: <<SeqNum:32, OpCode:8, Payload/binary>>
 * Response wire format: <<SeqNum:32, 0:8, OkPayload/binary>>    (ok)
 *                       <<SeqNum:32, 1:8, ErrMsg/binary>>        (error)
 *
 * Op codes:
 *   1  LOAD_LIB     payload: <<PathLen:16, Path:PathLen>>
 *                   ok:      <<Handle:64>>
 *   2  CALL         payload: <<Handle:64, NameLen:16, Name:NameLen,
 *                              RetType:8, Nargs:16, {ArgType:8, ArgVal}...>>
 *                   ok:      <<RetType:8, RetVal>>
 *   3  ALLOC        payload: <<Size:64>>
 *                   ok:      <<Addr:64>>
 *   4  FREE         payload: <<Addr:64>>
 *                   ok:      (empty)
 *   5  READ         payload: <<Addr:64, TypeCode:8>>
 *                   ok:      <<TypeCode:8, Value>>
 *   6  WRITE        payload: <<Addr:64, TypeCode:8, Value>>
 *                   ok:      (empty)
 *   7  READ_BYTES   payload: <<Addr:64, Size:32>>
 *                   ok:      <<Data:Size/bytes>>
 *   8  WRITE_BYTES  payload: <<Addr:64, Size:32, Data:Size/bytes>>
 *                   ok:      (empty)
 *   9  CALL_VA      payload: <<Handle:64, NameLen:16, Name:NameLen,
 *                              RetType:8, NFixed:16, Nargs:16, {ArgType:8, ArgVal}...>>
 *                   ok:      <<RetType:8, RetVal>>
 *                   NFixed: number of fixed (non-variadic) args (C default promotions
 *                           applied to variadic args by the Erlang side).
 *
 * Type codes (same in Erlang and C):
 *   0=void  1=int8  2=uint8  3=int16  4=uint16  5=int32  6=uint32
 *   7=int64 8=uint64 9=float 10=double 11=pointer 12=string 13=bool
 *
 * String arg encoding: <<Len:32, Data:Len>> (0xFFFFFFFF = NULL pointer)
 *
 * Pointer values are uint64 addresses in this process's address space.
 * A crash (SIGSEGV etc.) terminates this process only — the BEAM VM survives.
 */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <ffi.h>
#include <dlfcn.h>

/* =========================================================
 * Op and type constants (must match effi_port.erl)
 * ========================================================= */

#define OP_LOAD_LIB    1
#define OP_CALL        2
#define OP_ALLOC       3
#define OP_FREE        4
#define OP_READ        5
#define OP_WRITE       6
#define OP_READ_BYTES  7
#define OP_WRITE_BYTES 8
#define OP_CALL_VA     9

#define PT_VOID    0
#define PT_INT8    1
#define PT_UINT8   2
#define PT_INT16   3
#define PT_UINT16  4
#define PT_INT32   5
#define PT_UINT32  6
#define PT_INT64   7
#define PT_UINT64  8
#define PT_FLOAT   9
#define PT_DOUBLE  10
#define PT_POINTER 11
#define PT_STRING  12
#define PT_BOOL    13

#define STATUS_OK  0
#define STATUS_ERR 1

/* =========================================================
 * I/O helpers
 * ========================================================= */

static int read_exact(void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(0, (char *)buf + done, n - done);
        if (r <= 0) return 0;
        done += (size_t)r;
    }
    return 1;
}

static void write_exact(const void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = write(1, (const char *)buf + done, n - done);
        if (r <= 0) _exit(1);
        done += (size_t)r;
    }
}

/* =========================================================
 * Read buffer (cursor into received message)
 * ========================================================= */

typedef struct { const uint8_t *p; size_t rem; int ok; } rbuf;

static void rb_init(rbuf *r, const uint8_t *data, size_t len) {
    r->p = data; r->rem = len; r->ok = 1;
}
static void rb_need(rbuf *r, size_t n) { if (r->rem < n) r->ok = 0; }

static uint8_t rb_u8(rbuf *r) {
    rb_need(r, 1);
    if (!r->ok) return 0;
    uint8_t v = r->p[0]; r->p++; r->rem--; return v;
}
static uint16_t rb_u16(rbuf *r) {
    uint16_t v = (uint16_t)rb_u8(r) << 8; v |= rb_u8(r); return v;
}
static uint32_t rb_u32(rbuf *r) {
    uint32_t v = (uint32_t)rb_u16(r) << 16; v |= rb_u16(r); return v;
}
static uint64_t rb_u64(rbuf *r) {
    uint64_t v = (uint64_t)rb_u32(r) << 32; v |= rb_u32(r); return v;
}
static const uint8_t *rb_bytes(rbuf *r, size_t n) {
    rb_need(r, n);
    if (!r->ok) return r->p;
    const uint8_t *p = r->p; r->p += n; r->rem -= n; return p;
}

/* =========================================================
 * Write buffer (growable output accumulator)
 * ========================================================= */

typedef struct { uint8_t *data; size_t len; size_t cap; } wbuf;

static void wb_init(wbuf *b)  { b->data = NULL; b->len = 0; b->cap = 0; }
static void wb_free(wbuf *b)  { free(b->data); b->data = NULL; b->len = 0; b->cap = 0; }

static void wb_grow(wbuf *b, size_t need) {
    if (b->len + need <= b->cap) return;
    size_t ncap = (b->cap + need + 64) * 2;
    b->data = realloc(b->data, ncap);
    b->cap = ncap;
}
static void wb_u8(wbuf *b, uint8_t v) {
    wb_grow(b, 1); b->data[b->len++] = v;
}
static void wb_u16(wbuf *b, uint16_t v) { wb_u8(b, v >> 8); wb_u8(b, v); }
static void wb_u32(wbuf *b, uint32_t v) { wb_u16(b, v >> 16); wb_u16(b, v); }
static void wb_u64(wbuf *b, uint64_t v) { wb_u32(b, (uint32_t)(v >> 32)); wb_u32(b, (uint32_t)v); }
static void wb_bytes(wbuf *b, const void *data, size_t n) {
    wb_grow(b, n); memcpy(b->data + b->len, data, n); b->len += n;
}

/* Send a wbuf as a 4-byte length-prefixed frame */
static void wb_send(wbuf *b) {
    uint8_t hdr[4];
    uint32_t len = (uint32_t)b->len;
    hdr[0] = len >> 24; hdr[1] = len >> 16; hdr[2] = len >> 8; hdr[3] = len;
    write_exact(hdr, 4);
    write_exact(b->data, b->len);
}

/* =========================================================
 * Response helpers
 * ========================================================= */

static void send_ok_empty(uint32_t seq) {
    wbuf b; wb_init(&b);
    wb_u32(&b, seq);
    wb_u8(&b, STATUS_OK);
    wb_send(&b);
    wb_free(&b);
}

static void send_error(uint32_t seq, const char *msg) {
    wbuf b; wb_init(&b);
    wb_u32(&b, seq);
    wb_u8(&b, STATUS_ERR);
    wb_bytes(&b, msg, strlen(msg));
    wb_send(&b);
    wb_free(&b);
}

/* =========================================================
 * Type helpers
 * ========================================================= */

static ffi_type *pt_to_ffi(uint8_t t) {
    switch (t) {
    case PT_VOID:    return &ffi_type_void;
    case PT_BOOL:    return &ffi_type_uint8;
    case PT_INT8:    return &ffi_type_sint8;
    case PT_UINT8:   return &ffi_type_uint8;
    case PT_INT16:   return &ffi_type_sint16;
    case PT_UINT16:  return &ffi_type_uint16;
    case PT_INT32:   return &ffi_type_sint32;
    case PT_UINT32:  return &ffi_type_uint32;
    case PT_INT64:   return &ffi_type_sint64;
    case PT_UINT64:  return &ffi_type_uint64;
    case PT_FLOAT:   return &ffi_type_float;
    case PT_DOUBLE:  return &ffi_type_double;
    case PT_POINTER: return &ffi_type_pointer;
    case PT_STRING:  return &ffi_type_pointer;
    default:         return NULL;
    }
}

static size_t pt_size(uint8_t t) {
    switch (t) {
    case PT_VOID:              return 0;
    case PT_BOOL: case PT_INT8: case PT_UINT8:  return 1;
    case PT_INT16: case PT_UINT16:              return 2;
    case PT_INT32: case PT_UINT32: case PT_FLOAT: return 4;
    case PT_INT64: case PT_UINT64: case PT_DOUBLE:
    case PT_POINTER: case PT_STRING:            return 8;
    default:                                    return 0;
    }
}

/* Append a typed value from raw memory to a write buffer */
static void wb_typed(wbuf *b, uint8_t t, const void *src) {
    switch (t) {
    case PT_VOID: break;
    case PT_BOOL: case PT_INT8: case PT_UINT8:
        wb_u8(b, *(const uint8_t *)src); break;
    case PT_INT16: case PT_UINT16:
        wb_u16(b, *(const uint16_t *)src); break;
    case PT_INT32: case PT_UINT32: case PT_FLOAT:
        wb_u32(b, *(const uint32_t *)src); break;
    case PT_INT64: case PT_UINT64: case PT_DOUBLE:
        wb_u64(b, *(const uint64_t *)src); break;
    case PT_POINTER: {
        void *ptr; memcpy(&ptr, src, sizeof(void *));
        wb_u64(b, (uint64_t)(uintptr_t)ptr); break;
    }
    case PT_STRING: {
        char *str; memcpy(&str, src, sizeof(char *));
        if (!str) { wb_u32(b, 0xFFFFFFFFu); }
        else { uint32_t n = (uint32_t)strlen(str); wb_u32(b, n); wb_bytes(b, str, n); }
        break;
    }
    }
}

/* Read a typed arg value from rbuf into a C storage buffer (8 bytes max).
   For PT_STRING: allocates a null-terminated copy, written to str_out. */
static int rb_typed_arg(rbuf *r, uint8_t t, void *dst, char **str_out) {
    *str_out = NULL;
    switch (t) {
    case PT_BOOL: case PT_INT8: case PT_UINT8:
        *(uint8_t *)dst  = rb_u8(r); break;
    case PT_INT16: case PT_UINT16:
        *(uint16_t *)dst = rb_u16(r); break;
    case PT_INT32: case PT_UINT32: {
        uint32_t v = rb_u32(r); memcpy(dst, &v, 4); break;
    }
    case PT_FLOAT: {
        uint32_t bits = rb_u32(r); float f; memcpy(&f, &bits, 4);
        *(float *)dst = f; break;
    }
    case PT_INT64: case PT_UINT64: {
        uint64_t v = rb_u64(r); memcpy(dst, &v, 8); break;
    }
    case PT_DOUBLE: {
        uint64_t bits = rb_u64(r); double d; memcpy(&d, &bits, 8);
        *(double *)dst = d; break;
    }
    case PT_POINTER:
        *(void **)dst = (void *)(uintptr_t)rb_u64(r); break;
    case PT_STRING: {
        uint32_t len = rb_u32(r);
        if (len == 0xFFFFFFFFu) { *(void **)dst = NULL; }
        else {
            const uint8_t *bytes = rb_bytes(r, len);
            char *s = malloc(len + 1);
            if (!s) return 0;
            memcpy(s, bytes, len); s[len] = '\0';
            *(char **)dst = s;
            *str_out = s;
        }
        break;
    }
    default: return 0;
    }
    return r->ok;
}

/* =========================================================
 * Op handlers
 * ========================================================= */

static void op_load_lib(uint32_t seq, rbuf *r) {
    uint16_t plen = rb_u16(r);
    const uint8_t *pbytes = rb_bytes(r, plen);
    if (!r->ok) { send_error(seq, "bad request"); return; }

    char path[4096];
    if (plen >= sizeof(path)) { send_error(seq, "path too long"); return; }
    memcpy(path, pbytes, plen); path[plen] = '\0';

    dlerror();
    void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!handle) { send_error(seq, dlerror() ?: "dlopen failed"); return; }

    wbuf b; wb_init(&b);
    wb_u32(&b, seq); wb_u8(&b, STATUS_OK);
    wb_u64(&b, (uint64_t)(uintptr_t)handle);
    wb_send(&b); wb_free(&b);
}

static void op_call(uint32_t seq, rbuf *r) {
    uint64_t lib_handle = rb_u64(r);
    uint16_t fn_len     = rb_u16(r);
    const uint8_t *fn_bytes = rb_bytes(r, fn_len);
    uint8_t  ret_type   = rb_u8(r);
    uint16_t nargs      = rb_u16(r);

    if (!r->ok) { send_error(seq, "bad request"); return; }

    char fn_name[512];
    if (fn_len >= sizeof(fn_name)) { send_error(seq, "name too long"); return; }
    memcpy(fn_name, fn_bytes, fn_len); fn_name[fn_len] = '\0';

    void *lib = (void *)(uintptr_t)lib_handle;
    dlerror();
    void *fn = dlsym(lib, fn_name);
    if (!fn) { send_error(seq, dlerror() ?: "symbol not found"); return; }

    ffi_type **arg_types = nargs ? malloc(nargs * sizeof(ffi_type *)) : NULL;
    void     **arg_vals  = nargs ? malloc(nargs * sizeof(void *))     : NULL;
    uint8_t   *val_store = nargs ? calloc(nargs, 8)                   : NULL;
    char     **str_bufs  = nargs ? calloc(nargs, sizeof(char *))      : NULL;

    for (unsigned i = 0; i < nargs; i++) {
        uint8_t atype = rb_u8(r);
        arg_types[i]  = pt_to_ffi(atype);
        arg_vals[i]   = &val_store[i * 8];
        if (!rb_typed_arg(r, atype, arg_vals[i], &str_bufs[i])) {
            send_error(seq, "bad arg encoding");
            goto call_cleanup;
        }
    }
    if (!r->ok) { send_error(seq, "bad request"); goto call_cleanup; }

    {
        ffi_cif cif;
        ffi_status st = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, nargs,
                                      pt_to_ffi(ret_type),
                                      nargs ? arg_types : NULL);
        if (st != FFI_OK) { send_error(seq, "ffi_prep_cif failed"); goto call_cleanup; }

        uint8_t ret_buf[16] = {0};
        ffi_call(&cif, FFI_FN(fn), ret_buf, nargs ? arg_vals : NULL);

        wbuf b; wb_init(&b);
        wb_u32(&b, seq); wb_u8(&b, STATUS_OK);
        wb_u8(&b, ret_type);
        wb_typed(&b, ret_type, ret_buf);
        wb_send(&b); wb_free(&b);
    }

call_cleanup:
    if (str_bufs) { for (unsigned i = 0; i < nargs; i++) free(str_bufs[i]); free(str_bufs); }
    free(arg_types); free(arg_vals); free(val_store);
}

static void op_call_va(uint32_t seq, rbuf *r) {
    uint64_t lib_handle = rb_u64(r);
    uint16_t fn_len     = rb_u16(r);
    const uint8_t *fn_bytes = rb_bytes(r, fn_len);
    uint8_t  ret_type   = rb_u8(r);
    uint16_t nfixed     = rb_u16(r);
    uint16_t nargs      = rb_u16(r);

    if (!r->ok) { send_error(seq, "bad request"); return; }
    if (nfixed < 1 || nfixed > nargs) { send_error(seq, "bad nfixed"); return; }

    char fn_name[512];
    if (fn_len >= sizeof(fn_name)) { send_error(seq, "name too long"); return; }
    memcpy(fn_name, fn_bytes, fn_len); fn_name[fn_len] = '\0';

    void *lib = (void *)(uintptr_t)lib_handle;
    dlerror();
    void *fn = dlsym(lib, fn_name);
    if (!fn) { send_error(seq, dlerror() ?: "symbol not found"); return; }

    ffi_type **arg_types = malloc(nargs * sizeof(ffi_type *));
    void     **arg_vals  = malloc(nargs * sizeof(void *));
    uint8_t   *val_store = calloc(nargs, 8);
    char     **str_bufs  = calloc(nargs, sizeof(char *));

    for (unsigned i = 0; i < nargs; i++) {
        uint8_t atype = rb_u8(r);
        /* C default argument promotions for variadic args */
        if (i >= nfixed && atype == PT_FLOAT) atype = PT_DOUBLE;
        arg_types[i]  = pt_to_ffi(atype);
        arg_vals[i]   = &val_store[i * 8];
        if (!rb_typed_arg(r, atype, arg_vals[i], &str_bufs[i])) {
            send_error(seq, "bad arg encoding");
            goto va_cleanup;
        }
    }
    if (!r->ok) { send_error(seq, "bad request"); goto va_cleanup; }

    {
        ffi_cif cif;
        ffi_status st = ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, nfixed, nargs,
                                          pt_to_ffi(ret_type), arg_types);
        if (st != FFI_OK) { send_error(seq, "ffi_prep_cif_var failed"); goto va_cleanup; }

        uint8_t ret_buf[16] = {0};
        ffi_call(&cif, FFI_FN(fn), ret_buf, arg_vals);

        wbuf b; wb_init(&b);
        wb_u32(&b, seq); wb_u8(&b, STATUS_OK);
        wb_u8(&b, ret_type);
        wb_typed(&b, ret_type, ret_buf);
        wb_send(&b); wb_free(&b);
    }

va_cleanup:
    if (str_bufs) { for (unsigned i = 0; i < nargs; i++) free(str_bufs[i]); free(str_bufs); }
    free(arg_types); free(arg_vals); free(val_store);
}

static void op_alloc(uint32_t seq, rbuf *r) {
    uint64_t size = rb_u64(r);
    if (!r->ok || size == 0) { send_error(seq, "bad size"); return; }

    void *ptr = calloc(1, (size_t)size);
    if (!ptr) { send_error(seq, "alloc failed"); return; }

    wbuf b; wb_init(&b);
    wb_u32(&b, seq); wb_u8(&b, STATUS_OK);
    wb_u64(&b, (uint64_t)(uintptr_t)ptr);
    wb_send(&b); wb_free(&b);
}

static void op_free(uint32_t seq, rbuf *r) {
    uint64_t addr = rb_u64(r);
    if (!r->ok) { send_error(seq, "bad request"); return; }
    free((void *)(uintptr_t)addr);
    send_ok_empty(seq);
}

static void op_read(uint32_t seq, rbuf *r) {
    uint64_t addr = rb_u64(r);
    uint8_t  t    = rb_u8(r);
    if (!r->ok) { send_error(seq, "bad request"); return; }

    void *ptr = (void *)(uintptr_t)addr;
    /* For string: ptr IS the char*, pass &ptr so wb_typed reads char** */
    void *src = (t == PT_STRING) ? (void *)&ptr : ptr;

    wbuf b; wb_init(&b);
    wb_u32(&b, seq); wb_u8(&b, STATUS_OK);
    wb_u8(&b, t);
    wb_typed(&b, t, src);
    wb_send(&b); wb_free(&b);
}

static void op_write(uint32_t seq, rbuf *r) {
    uint64_t addr = rb_u64(r);
    uint8_t  t    = rb_u8(r);
    if (!r->ok) { send_error(seq, "bad request"); return; }

    void *ptr = (void *)(uintptr_t)addr;
    char *str_buf = NULL;

    if (t == PT_STRING) {
        /* Write string bytes into the buffer at ptr */
        uint32_t len = rb_u32(r);
        if (len == 0xFFFFFFFFu) {
            *(void **)ptr = NULL;
        } else {
            const uint8_t *bytes = rb_bytes(r, len);
            if (!r->ok) { send_error(seq, "bad request"); return; }
            memcpy(ptr, bytes, len);
            ((char *)ptr)[len] = '\0';
        }
    } else {
        uint8_t buf[8] = {0};
        if (!rb_typed_arg(r, t, buf, &str_buf)) {
            send_error(seq, "bad value encoding"); return;
        }
        if (str_buf) free(str_buf);
        memcpy(ptr, buf, pt_size(t));
    }
    if (!r->ok) { send_error(seq, "bad request"); return; }
    send_ok_empty(seq);
}

static void op_read_bytes(uint32_t seq, rbuf *r) {
    uint64_t addr = rb_u64(r);
    uint32_t size = rb_u32(r);
    if (!r->ok || size == 0) { send_error(seq, "bad request"); return; }

    wbuf b; wb_init(&b);
    wb_u32(&b, seq); wb_u8(&b, STATUS_OK);
    wb_bytes(&b, (void *)(uintptr_t)addr, size);
    wb_send(&b); wb_free(&b);
}

static void op_write_bytes(uint32_t seq, rbuf *r) {
    uint64_t addr = rb_u64(r);
    uint32_t size = rb_u32(r);
    const uint8_t *data = rb_bytes(r, size);
    if (!r->ok) { send_error(seq, "bad request"); return; }
    memcpy((void *)(uintptr_t)addr, data, size);
    send_ok_empty(seq);
}

/* =========================================================
 * Main loop
 * ========================================================= */

int main(void) {
    /* Binary I/O: avoid any buffering on stdio */
    close(2);  /* close stderr so C library errors don't leak to Erlang */

    for (;;) {
        /* Read 4-byte big-endian frame length */
        uint8_t hdr[4];
        if (!read_exact(hdr, 4)) break;   /* EOF = port closed */
        uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                       ((uint32_t)hdr[2] << 8)  |  (uint32_t)hdr[3];

        uint8_t *frame = malloc(len);
        if (!frame || !read_exact(frame, len)) break;

        rbuf r;
        rb_init(&r, frame, len);

        uint32_t seq = rb_u32(&r);
        uint8_t  op  = rb_u8(&r);

        switch (op) {
        case OP_LOAD_LIB:    op_load_lib(seq, &r);    break;
        case OP_CALL:        op_call(seq, &r);         break;
        case OP_ALLOC:       op_alloc(seq, &r);        break;
        case OP_FREE:        op_free(seq, &r);         break;
        case OP_READ:        op_read(seq, &r);         break;
        case OP_WRITE:       op_write(seq, &r);        break;
        case OP_READ_BYTES:  op_read_bytes(seq, &r);   break;
        case OP_WRITE_BYTES: op_write_bytes(seq, &r);  break;
        case OP_CALL_VA:     op_call_va(seq, &r);      break;
        default: {
            char msg[32];
            snprintf(msg, sizeof(msg), "unknown op: %u", op);
            send_error(seq, msg);
            break;
        }
        }

        free(frame);
    }
    return 0;
}
