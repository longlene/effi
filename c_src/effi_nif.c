/*
 * effi_nif.c — Erlang CFFI NIF core
 *
 * Resource types:
 *   effi_lib   dlopen handle (GC → dlclose)
 *   effi_ptr   void* wrapper (owned → GC free; borrowed → no-op)
 *              May hold a "parent" reference to an effi_cb keeping it alive.
 *   effi_cb    libffi closure + pthread sync state (GC → ffi_closure_free)
 *
 * Callback protocol (C→Erlang):
 *   1. effi_nif:callback_new(RetType, ArgTypes, ServerPid)
 *        → {ok, {CbHandle :: resource, FuncPtr :: resource}}
 *   2. When C calls FuncPtr, the trampoline:
 *        a. marshals C args → Erlang terms
 *        b. sends {effi_callback, CbId :: uint64, ArgList} to ServerPid
 *        c. blocks on pthread condvar
 *   3. Server process calls Fun(Args...) and replies via:
 *        effi_nif:callback_return(CbId, RetVal)
 *   4. Trampoline wakes, fills C return buffer, returns to C.
 *
 * Limitation: callbacks are not re-entrant per closure instance.
 */

#include <erl_nif.h>
#include <ffi.h>
#include <dlfcn.h>
#include <pthread.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* =========================================================
 * Resource type declarations
 * ========================================================= */

static ErlNifResourceType *g_lib_rtype = NULL;
static ErlNifResourceType *g_ptr_rtype = NULL;
static ErlNifResourceType *g_cb_rtype  = NULL;

/* Library handle */
typedef struct {
    void *handle;
} effi_lib_t;

/* Generic C pointer, optionally owning a "parent" effi_cb resource */
typedef struct {
    void  *ptr;
    int    owned;    /* 1 → free on GC; 0 → borrowed */
    size_t size;
    void  *parent;   /* if non-NULL: an effi_cb_t* kept alive via enif_keep_resource */
} effi_ptr_t;

/* Callback closure + synchronization state */
typedef struct {
    ffi_closure    *closure;
    void           *code_ptr;   /* the callable function pointer given to C */
    ffi_cif         cif;
    ffi_type      **arg_types;  /* heap-allocated array, length = nargs */
    unsigned        nargs;

    /* Type info needed by the trampoline */
    int            *arg_tids;   /* effi_tid per arg */
    int             ret_tid;    /* effi_tid for return */

    /* Erlang callback server process */
    ErlNifPid       server_pid;

    /* Synchronization: C trampoline blocks until Erlang replies */
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    int             waiting;    /* 1 = trampoline is blocked */
    uint8_t         ret_buf[16];/* return value written by callback_return */
} effi_cb_t;

/* =========================================================
 * Destructors
 * ========================================================= */

static void lib_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    effi_lib_t *lib = (effi_lib_t *)obj;
    if (lib->handle) { dlclose(lib->handle); lib->handle = NULL; }
}

static void ptr_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    effi_ptr_t *p = (effi_ptr_t *)obj;
    if (p->owned && p->ptr) { free(p->ptr); p->ptr = NULL; p->owned = 0; }
    if (p->parent)          { enif_release_resource(p->parent); p->parent = NULL; }
}

static void cb_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    effi_cb_t *cb = (effi_cb_t *)obj;
    if (cb->closure) { ffi_closure_free(cb->closure); cb->closure = NULL; }
    free(cb->arg_types);
    free(cb->arg_tids);
    pthread_mutex_destroy(&cb->lock);
    pthread_cond_destroy(&cb->cond);
}

/* =========================================================
 * Atom cache
 * ========================================================= */

static ERL_NIF_TERM am_ok, am_error, am_true, am_false, am_null;
static ERL_NIF_TERM am_void, am_bool;
static ERL_NIF_TERM am_int8, am_uint8, am_int16, am_uint16;
static ERL_NIF_TERM am_int32, am_uint32, am_int64, am_uint64;
static ERL_NIF_TERM am_float, am_double, am_pointer, am_string;
static ERL_NIF_TERM am_not_found, am_bad_type, am_ffi_error;
static ERL_NIF_TERM am_not_owner, am_alloc_failed, am_library_closed;
static ERL_NIF_TERM am_bad_nfixed;
static ERL_NIF_TERM am_effi_callback;   /* message tag for callbacks */

#define MK_ATOM(n_) am_##n_ = enif_make_atom(env, #n_)

static void init_atoms(ErlNifEnv *env) {
    MK_ATOM(ok);   MK_ATOM(error);  MK_ATOM(true);  MK_ATOM(false);
    MK_ATOM(null); MK_ATOM(void);   MK_ATOM(bool);
    MK_ATOM(int8);   MK_ATOM(uint8);
    MK_ATOM(int16);  MK_ATOM(uint16);
    MK_ATOM(int32);  MK_ATOM(uint32);
    MK_ATOM(int64);  MK_ATOM(uint64);
    MK_ATOM(float);  MK_ATOM(double);
    MK_ATOM(pointer); MK_ATOM(string);
    am_not_found      = enif_make_atom(env, "not_found");
    am_bad_type       = enif_make_atom(env, "bad_type");
    am_ffi_error      = enif_make_atom(env, "ffi_error");
    am_bad_nfixed     = enif_make_atom(env, "bad_nfixed");
    am_not_owner      = enif_make_atom(env, "not_owner");
    am_alloc_failed   = enif_make_atom(env, "alloc_failed");
    am_library_closed = enif_make_atom(env, "library_closed");
    am_effi_callback  = enif_make_atom(env, "effi_callback");
}

/* =========================================================
 * Type system
 * ========================================================= */

typedef enum {
    T_VOID = 0,
    T_BOOL,
    T_INT8,  T_UINT8,
    T_INT16, T_UINT16,
    T_INT32, T_UINT32,
    T_INT64, T_UINT64,
    T_FLOAT, T_DOUBLE,
    T_POINTER,
    T_STRING,
    T_UNKNOWN = -1
} effi_tid;

static effi_tid atom_to_tid(ERL_NIF_TERM a) {
    if (enif_is_identical(a, am_void))    return T_VOID;
    if (enif_is_identical(a, am_bool))    return T_BOOL;
    if (enif_is_identical(a, am_int8))    return T_INT8;
    if (enif_is_identical(a, am_uint8))   return T_UINT8;
    if (enif_is_identical(a, am_int16))   return T_INT16;
    if (enif_is_identical(a, am_uint16))  return T_UINT16;
    if (enif_is_identical(a, am_int32))   return T_INT32;
    if (enif_is_identical(a, am_uint32))  return T_UINT32;
    if (enif_is_identical(a, am_int64))   return T_INT64;
    if (enif_is_identical(a, am_uint64))  return T_UINT64;
    if (enif_is_identical(a, am_float))   return T_FLOAT;
    if (enif_is_identical(a, am_double))  return T_DOUBLE;
    if (enif_is_identical(a, am_pointer)) return T_POINTER;
    if (enif_is_identical(a, am_string))  return T_STRING;
    return T_UNKNOWN;
}

static ffi_type *tid_to_ffi(effi_tid t) {
    switch (t) {
    case T_VOID:    return &ffi_type_void;
    case T_BOOL:    return &ffi_type_uint8;
    case T_INT8:    return &ffi_type_sint8;
    case T_UINT8:   return &ffi_type_uint8;
    case T_INT16:   return &ffi_type_sint16;
    case T_UINT16:  return &ffi_type_uint16;
    case T_INT32:   return &ffi_type_sint32;
    case T_UINT32:  return &ffi_type_uint32;
    case T_INT64:   return &ffi_type_sint64;
    case T_UINT64:  return &ffi_type_uint64;
    case T_FLOAT:   return &ffi_type_float;
    case T_DOUBLE:  return &ffi_type_double;
    case T_POINTER: return &ffi_type_pointer;
    case T_STRING:  return &ffi_type_pointer;
    default:        return NULL;
    }
}

static size_t tid_size(effi_tid t) {
    switch (t) {
    case T_VOID:              return 0;
    case T_BOOL:
    case T_INT8:  case T_UINT8:  return 1;
    case T_INT16: case T_UINT16: return 2;
    case T_INT32: case T_UINT32: return 4;
    case T_INT64: case T_UINT64: return 8;
    case T_FLOAT:             return sizeof(float);
    case T_DOUBLE:            return sizeof(double);
    case T_POINTER:
    case T_STRING:            return sizeof(void *);
    default:                  return 0;
    }
}

/* =========================================================
 * Marshaling
 * ========================================================= */

/*
 * marshal_arg: Erlang term → raw C bytes in dst (8-byte buffer).
 * For T_STRING: allocates null-terminated copy → *str_out (caller frees).
 * Returns 0 on success, -1 on type mismatch.
 */
static int marshal_arg(ErlNifEnv *env, effi_tid tid,
                       ERL_NIF_TERM val, void *dst, char **str_out) {
    ErlNifSInt64 i64;
    ErlNifUInt64 u64;
    double dbl;
    effi_ptr_t *p;
    ErlNifBinary bin;

    *str_out = NULL;

    switch (tid) {
    case T_BOOL:
        if (!enif_get_uint64(env, val, &u64)) {
            if (enif_is_identical(val, am_true))  u64 = 1;
            else if (enif_is_identical(val, am_false)) u64 = 0;
            else return -1;
        }
        *(uint8_t *)dst = (uint8_t)(u64 ? 1 : 0); return 0;
    case T_INT8:
        if (!enif_get_int64(env, val, &i64))  return -1;
        *(int8_t  *)dst = (int8_t)i64;         return 0;
    case T_UINT8:
        if (!enif_get_uint64(env, val, &u64)) return -1;
        *(uint8_t *)dst = (uint8_t)u64;        return 0;
    case T_INT16:
        if (!enif_get_int64(env, val, &i64))  return -1;
        *(int16_t *)dst = (int16_t)i64;        return 0;
    case T_UINT16:
        if (!enif_get_uint64(env, val, &u64)) return -1;
        *(uint16_t*)dst = (uint16_t)u64;       return 0;
    case T_INT32:
        if (!enif_get_int64(env, val, &i64))  return -1;
        *(int32_t *)dst = (int32_t)i64;        return 0;
    case T_UINT32:
        if (!enif_get_uint64(env, val, &u64)) return -1;
        *(uint32_t*)dst = (uint32_t)u64;       return 0;
    case T_INT64:
        if (!enif_get_int64(env, val, &i64))  return -1;
        *(int64_t *)dst = i64;                 return 0;
    case T_UINT64:
        if (!enif_get_uint64(env, val, &u64)) return -1;
        *(uint64_t*)dst = u64;                 return 0;
    case T_FLOAT:
        if (!enif_get_double(env, val, &dbl)) return -1;
        *(float   *)dst = (float)dbl;          return 0;
    case T_DOUBLE:
        if (!enif_get_double(env, val, &dbl)) return -1;
        *(double  *)dst = dbl;                 return 0;
    case T_POINTER:
        if (enif_is_identical(val, am_null)) { *(void **)dst = NULL; return 0; }
        if (!enif_get_resource(env, val, g_ptr_rtype, (void **)&p)) return -1;
        *(void **)dst = p->ptr;                return 0;
    case T_STRING:
        if (enif_is_identical(val, am_null)) { *(void **)dst = NULL; return 0; }
        if (!enif_inspect_iolist_as_binary(env, val, &bin)) return -1;
        *str_out = (char *)malloc(bin.size + 1);
        if (!*str_out) return -1;
        memcpy(*str_out, bin.data, bin.size);
        (*str_out)[bin.size] = '\0';
        *(char **)dst = *str_out;              return 0;
    default:
        return -1;
    }
}

/* marshal_ret: C value at src → Erlang term. src is a pointer to the value. */
static ERL_NIF_TERM marshal_ret(ErlNifEnv *env, effi_tid tid, void *src) {
    effi_ptr_t  *res;
    ERL_NIF_TERM bin_term;
    unsigned char *bin_data;
    char *str;

    switch (tid) {
    case T_VOID:
        return am_ok;
    case T_BOOL:   return *(uint8_t *)src ? am_true : am_false;
    case T_INT8:   return enif_make_int64(env,  *(int8_t   *)src);
    case T_UINT8:  return enif_make_uint64(env, *(uint8_t  *)src);
    case T_INT16:  return enif_make_int64(env,  *(int16_t  *)src);
    case T_UINT16: return enif_make_uint64(env, *(uint16_t *)src);
    case T_INT32:  return enif_make_int64(env,  *(int32_t  *)src);
    case T_UINT32: return enif_make_uint64(env, *(uint32_t *)src);
    case T_INT64:  return enif_make_int64(env,  *(int64_t  *)src);
    case T_UINT64: return enif_make_uint64(env, *(uint64_t *)src);
    case T_FLOAT:  return enif_make_double(env, (double)*(float  *)src);
    case T_DOUBLE: return enif_make_double(env, *(double *)src);
    case T_POINTER: {
        void *raw = *(void **)src;
        if (!raw) return am_null;
        res = enif_alloc_resource(g_ptr_rtype, sizeof(effi_ptr_t));
        if (!res) return am_null;
        res->ptr = raw; res->owned = 0; res->size = 0; res->parent = NULL;
        ERL_NIF_TERM t = enif_make_resource(env, res);
        enif_release_resource(res);
        return t;
    }
    case T_STRING: {
        str = *(char **)src;
        if (!str) return am_null;
        size_t slen = strlen(str);
        bin_data = enif_make_new_binary(env, slen, &bin_term);
        memcpy(bin_data, str, slen);
        return bin_term;
    }
    default:
        return am_error;
    }
}

/* =========================================================
 * NIF: lib_open/1
 * ========================================================= */
static ERL_NIF_TERM nif_lib_open(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    char path[4096];
    void *handle;
    effi_lib_t *lib;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_string(env, argv[0], path, sizeof(path), ERL_NIF_UTF8))
        return enif_make_badarg(env);

    dlerror();
    handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!handle)
        return enif_make_tuple2(env, am_error,
            enif_make_string(env, dlerror() ?: "unknown", ERL_NIF_UTF8));

    lib = enif_alloc_resource(g_lib_rtype, sizeof(effi_lib_t));
    if (!lib) { dlclose(handle); return enif_make_tuple2(env, am_error, am_alloc_failed); }
    lib->handle = handle;

    ERL_NIF_TERM res = enif_make_resource(env, lib);
    enif_release_resource(lib);
    return enif_make_tuple2(env, am_ok, res);
}

/* =========================================================
 * NIF: call/4  (dirty CPU scheduler)
 *   call(Lib, FuncName, RetType, [{ArgType, ArgVal}])
 *       -> {ok, RetVal} | {error, Reason}
 * ========================================================= */
static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    effi_lib_t *lib;
    char func_name[512];
    void *fn_ptr;
    effi_tid ret_tid;
    unsigned nargs = 0;
    ERL_NIF_TERM list, head, tail;
    ERL_NIF_TERM result = am_error;

    ffi_type  **arg_types = NULL;
    void      **arg_vals  = NULL;
    uint8_t    *val_store = NULL;
    char      **str_bufs  = NULL;

    if (argc != 4) return enif_make_badarg(env);

    if (!enif_get_resource(env, argv[0], g_lib_rtype, (void **)&lib))
        return enif_make_badarg(env);
    if (!lib->handle)
        return enif_make_tuple2(env, am_error, am_library_closed);

    if (!enif_get_string(env, argv[1], func_name, sizeof(func_name), ERL_NIF_UTF8))
        return enif_make_badarg(env);

    dlerror();
    fn_ptr = dlsym(lib->handle, func_name);
    if (!fn_ptr) {
        const char *err = dlerror();
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_not_found,
                enif_make_string(env, err ? err : func_name, ERL_NIF_UTF8)));
    }

    ret_tid = atom_to_tid(argv[2]);
    if (ret_tid == T_UNKNOWN)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_type, argv[2]));

    /* Count args */
    list = argv[3];
    { ERL_NIF_TERM t = list;
      while (enif_get_list_cell(env, t, &head, &tail)) { nargs++; t = tail; }
      if (!enif_is_empty_list(env, t)) return enif_make_badarg(env); }

    if (nargs > 0) {
        arg_types = malloc(nargs * sizeof(ffi_type *));
        arg_vals  = malloc(nargs * sizeof(void *));
        val_store = calloc(nargs, 8);
        str_bufs  = calloc(nargs, sizeof(char *));
        if (!arg_types || !arg_vals || !val_store || !str_bufs) {
            result = enif_make_tuple2(env, am_error, am_alloc_failed);
            goto cleanup;
        }
    }

    /* Marshal args */
    { unsigned i = 0;
      ERL_NIF_TERM t = list;
      while (enif_get_list_cell(env, t, &head, &tail)) {
          int ar; const ERL_NIF_TERM *pair;
          if (!enif_get_tuple(env, head, &ar, &pair) || ar != 2) {
              result = enif_make_badarg(env); goto cleanup;
          }
          effi_tid tid = atom_to_tid(pair[0]);
          if (tid == T_UNKNOWN || tid == T_VOID) {
              result = enif_make_tuple2(env, am_error,
                  enif_make_tuple2(env, am_bad_type, pair[0]));
              goto cleanup;
          }
          arg_types[i] = tid_to_ffi(tid);
          arg_vals[i]  = &val_store[i * 8];
          if (marshal_arg(env, tid, pair[1], arg_vals[i], &str_bufs[i]) != 0) {
              result = enif_make_tuple2(env, am_error,
                  enif_make_tuple2(env, am_bad_type, head));
              goto cleanup;
          }
          i++; t = tail;
      }
    }

    /* Prepare and call */
    { ffi_cif cif;
      ffi_status st = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, nargs,
                                    tid_to_ffi(ret_tid),
                                    nargs ? arg_types : NULL);
      if (st != FFI_OK) {
          result = enif_make_tuple2(env, am_error,
              enif_make_tuple2(env, am_ffi_error, enif_make_int(env, (int)st)));
          goto cleanup;
      }
      uint8_t ret_buf[16] = {0};
      ffi_call(&cif, FFI_FN(fn_ptr), ret_buf, nargs ? arg_vals : NULL);
      result = enif_make_tuple2(env, am_ok, marshal_ret(env, ret_tid, ret_buf));
    }

cleanup:
    if (str_bufs) {
        for (unsigned i = 0; i < nargs; i++) if (str_bufs[i]) free(str_bufs[i]);
        free(str_bufs);
    }
    free(arg_types); free(arg_vals); free(val_store);
    return result;
}

/* =========================================================
 * NIF: call_va/5  (dirty CPU scheduler)
 *   call_va(Lib, FuncName, RetType, NFixed, [{ArgType, ArgVal}])
 *       -> {ok, RetVal} | {error, Reason}
 *
 * NFixed: number of fixed (non-variadic) arguments.
 *   Must satisfy 1 <= NFixed <= length(Args).
 * ========================================================= */
static ERL_NIF_TERM nif_call_va(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    effi_lib_t *lib;
    char func_name[512];
    void *fn_ptr;
    effi_tid ret_tid;
    unsigned nfixed = 0, nargs = 0;
    ERL_NIF_TERM list, head, tail;
    ERL_NIF_TERM result = am_error;

    ffi_type  **arg_types = NULL;
    void      **arg_vals  = NULL;
    uint8_t    *val_store = NULL;
    char      **str_bufs  = NULL;

    if (argc != 5) return enif_make_badarg(env);

    if (!enif_get_resource(env, argv[0], g_lib_rtype, (void **)&lib))
        return enif_make_badarg(env);
    if (!lib->handle)
        return enif_make_tuple2(env, am_error, am_library_closed);

    if (!enif_get_string(env, argv[1], func_name, sizeof(func_name), ERL_NIF_UTF8))
        return enif_make_badarg(env);

    dlerror();
    fn_ptr = dlsym(lib->handle, func_name);
    if (!fn_ptr) {
        const char *err = dlerror();
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_not_found,
                enif_make_string(env, err ? err : func_name, ERL_NIF_UTF8)));
    }

    ret_tid = atom_to_tid(argv[2]);
    if (ret_tid == T_UNKNOWN)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_type, argv[2]));

    if (!enif_get_uint(env, argv[3], &nfixed))
        return enif_make_badarg(env);

    /* Count args */
    list = argv[4];
    { ERL_NIF_TERM t = list;
      while (enif_get_list_cell(env, t, &head, &tail)) { nargs++; t = tail; }
      if (!enif_is_empty_list(env, t)) return enif_make_badarg(env); }

    if (nfixed < 1 || nfixed > nargs)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_nfixed, enif_make_uint(env, nfixed)));

    if (nargs > 0) {
        arg_types = malloc(nargs * sizeof(ffi_type *));
        arg_vals  = malloc(nargs * sizeof(void *));
        val_store = calloc(nargs, 8);
        str_bufs  = calloc(nargs, sizeof(char *));
        if (!arg_types || !arg_vals || !val_store || !str_bufs) {
            result = enif_make_tuple2(env, am_error, am_alloc_failed);
            goto va_cleanup;
        }
    }

    /* Marshal args */
    { unsigned i = 0;
      ERL_NIF_TERM t = list;
      while (enif_get_list_cell(env, t, &head, &tail)) {
          int ar; const ERL_NIF_TERM *pair;
          if (!enif_get_tuple(env, head, &ar, &pair) || ar != 2) {
              result = enif_make_badarg(env); goto va_cleanup;
          }
          effi_tid tid = atom_to_tid(pair[0]);
          if (tid == T_UNKNOWN || tid == T_VOID) {
              result = enif_make_tuple2(env, am_error,
                  enif_make_tuple2(env, am_bad_type, pair[0]));
              goto va_cleanup;
          }
          /* Variadic args: promote float→double per C default argument promotions */
          if (i >= nfixed && tid == T_FLOAT) tid = T_DOUBLE;
          arg_types[i] = tid_to_ffi(tid);
          arg_vals[i]  = &val_store[i * 8];
          if (marshal_arg(env, tid, pair[1], arg_vals[i], &str_bufs[i]) != 0) {
              result = enif_make_tuple2(env, am_error,
                  enif_make_tuple2(env, am_bad_type, head));
              goto va_cleanup;
          }
          i++; t = tail;
      }
    }

    /* Prepare and call using ffi_prep_cif_var */
    { ffi_cif cif;
      ffi_status st = ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, nfixed, nargs,
                                        tid_to_ffi(ret_tid),
                                        arg_types);
      if (st != FFI_OK) {
          result = enif_make_tuple2(env, am_error,
              enif_make_tuple2(env, am_ffi_error, enif_make_int(env, (int)st)));
          goto va_cleanup;
      }
      uint8_t ret_buf[16] = {0};
      ffi_call(&cif, FFI_FN(fn_ptr), ret_buf, arg_vals);
      result = enif_make_tuple2(env, am_ok, marshal_ret(env, ret_tid, ret_buf));
    }

va_cleanup:
    if (str_bufs) {
        for (unsigned i = 0; i < nargs; i++) if (str_bufs[i]) free(str_bufs[i]);
        free(str_bufs);
    }
    free(arg_types); free(arg_vals); free(val_store);
    return result;
}

/* =========================================================
 * NIF: mem_alloc/1
 * ========================================================= */
static ERL_NIF_TERM nif_mem_alloc(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    ErlNifUInt64 size;
    effi_ptr_t  *p;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[0], &size) || size == 0)
        return enif_make_badarg(env);

    p = enif_alloc_resource(g_ptr_rtype, sizeof(effi_ptr_t));
    if (!p) return enif_make_tuple2(env, am_error, am_alloc_failed);
    p->ptr = calloc(1, (size_t)size);
    if (!p->ptr) {
        enif_release_resource(p);
        return enif_make_tuple2(env, am_error, am_alloc_failed);
    }
    p->owned = 1; p->size = (size_t)size; p->parent = NULL;

    ERL_NIF_TERM res = enif_make_resource(env, p);
    enif_release_resource(p);
    return res;
}

/* =========================================================
 * NIF: mem_free/1
 * ========================================================= */
static ERL_NIF_TERM nif_mem_free(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    effi_ptr_t *p;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    if (!p->owned) return enif_make_tuple2(env, am_error, am_not_owner);
    if (p->ptr) { free(p->ptr); p->ptr = NULL; p->owned = 0; }
    return am_ok;
}

/* =========================================================
 * NIF: mem_read/2
 *   string → p->ptr IS the char buffer (pass &p->ptr for marshal_ret)
 *   pointer → p->ptr points to a void* field (dereference it)
 *   numeric → p->ptr points to the value
 * ========================================================= */
static ERL_NIF_TERM nif_mem_read(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    effi_ptr_t *p;
    effi_tid tid;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    if (!p->ptr) return enif_make_tuple2(env, am_error, am_null);

    tid = atom_to_tid(argv[1]);
    if (tid == T_UNKNOWN || tid == T_VOID)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_type, argv[1]));

    void *src = (tid == T_STRING) ? (void *)&p->ptr : p->ptr;
    return marshal_ret(env, tid, src);
}

/* =========================================================
 * NIF: mem_write/3
 * ========================================================= */
static ERL_NIF_TERM nif_mem_write(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    effi_ptr_t *p;
    effi_tid tid;

    if (argc != 3) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    if (!p->ptr) return enif_make_tuple2(env, am_error, am_null);

    tid = atom_to_tid(argv[1]);
    if (tid == T_UNKNOWN || tid == T_VOID)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_type, argv[1]));

    ERL_NIF_TERM val = argv[2];

    if (tid == T_STRING) {
        ErlNifBinary bin;
        if (!enif_inspect_iolist_as_binary(env, val, &bin))
            return enif_make_badarg(env);
        if (p->size > 0 && bin.size + 1 > p->size)
            return enif_make_tuple2(env, am_error,
                enif_make_atom(env, "buffer_overflow"));
        memcpy(p->ptr, bin.data, bin.size);
        ((char *)p->ptr)[bin.size] = '\0';
        return am_ok;
    }

    if (tid == T_POINTER) {
        void *raw;
        if (enif_is_identical(val, am_null)) {
            raw = NULL;
        } else {
            effi_ptr_t *src_p;
            if (!enif_get_resource(env, val, g_ptr_rtype, (void **)&src_p))
                return enif_make_badarg(env);
            raw = src_p->ptr;
        }
        memcpy(p->ptr, &raw, sizeof(void *));
        return am_ok;
    }

    uint8_t buf[8] = {0};
    char *str_buf = NULL;
    if (marshal_arg(env, tid, val, buf, &str_buf) != 0)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_type, val));
    if (str_buf) free(str_buf);
    memcpy(p->ptr, buf, tid_size(tid));
    return am_ok;
}

/* =========================================================
 * NIF: mem_read_bytes/2, mem_write_bytes/2
 * ========================================================= */
static ERL_NIF_TERM nif_mem_read_bytes(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    effi_ptr_t  *p;
    ErlNifUInt64 size;
    ERL_NIF_TERM bin_term;
    unsigned char *data;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[1], &size) || size == 0)
        return enif_make_badarg(env);
    if (!p->ptr) return enif_make_tuple2(env, am_error, am_null);

    data = enif_make_new_binary(env, (size_t)size, &bin_term);
    memcpy(data, p->ptr, (size_t)size);
    return bin_term;
}

static ERL_NIF_TERM nif_mem_write_bytes(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    effi_ptr_t *p;
    ErlNifBinary bin;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &bin))
        return enif_make_badarg(env);
    if (!p->ptr) return enif_make_tuple2(env, am_error, am_null);

    memcpy(p->ptr, bin.data, bin.size);
    return am_ok;
}

/* =========================================================
 * NIF: ptr_add/2, ptr_null/0, ptr_is_null/1, type_size/1
 * ========================================================= */
static ERL_NIF_TERM nif_ptr_add(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    effi_ptr_t *p, *newp;
    ErlNifSInt64 offset;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    if (!enif_get_int64(env, argv[1], &offset))
        return enif_make_badarg(env);
    if (!p->ptr) return enif_make_tuple2(env, am_error, am_null);

    newp = enif_alloc_resource(g_ptr_rtype, sizeof(effi_ptr_t));
    if (!newp) return enif_make_tuple2(env, am_error, am_alloc_failed);
    newp->ptr    = (uint8_t *)p->ptr + offset;
    newp->owned  = 0;
    newp->size   = 0;
    newp->parent = NULL;

    ERL_NIF_TERM res = enif_make_resource(env, newp);
    enif_release_resource(newp);
    return res;
}

static ERL_NIF_TERM nif_ptr_null(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    effi_ptr_t *p = enif_alloc_resource(g_ptr_rtype, sizeof(effi_ptr_t));
    if (!p) return enif_make_tuple2(env, am_error, am_alloc_failed);
    p->ptr = NULL; p->owned = 0; p->size = 0; p->parent = NULL;
    ERL_NIF_TERM res = enif_make_resource(env, p);
    enif_release_resource(p);
    return res;
}

static ERL_NIF_TERM nif_ptr_is_null(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    effi_ptr_t *p;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], g_ptr_rtype, (void **)&p))
        return enif_make_badarg(env);
    return p->ptr ? am_false : am_true;
}

static ERL_NIF_TERM nif_type_size(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    effi_tid tid;
    if (argc != 1) return enif_make_badarg(env);
    tid = atom_to_tid(argv[0]);
    if (tid == T_UNKNOWN)
        return enif_make_tuple2(env, am_error,
            enif_make_tuple2(env, am_bad_type, argv[0]));
    return enif_make_uint64(env, (uint64_t)tid_size(tid));
}

/* =========================================================
 * Callback: trampoline (called by C code via the function pointer)
 *
 * Runs in whatever thread made the C call (typically a dirty NIF thread).
 * Sends {effi_callback, CbId, [Arg...]} to the server process,
 * then blocks until callback_return is called.
 * ========================================================= */
static void callback_trampoline(ffi_cif *cif, void *ret,
                                 void **args, void *user_data) {
    effi_cb_t *cb = (effi_cb_t *)user_data;
    (void)cif;

    /* Build Erlang arg list in a fresh message env */
    ErlNifEnv *msg_env = enif_alloc_env();

    ERL_NIF_TERM arg_list = enif_make_list(msg_env, 0);
    for (int i = (int)cb->nargs - 1; i >= 0; i--) {
        ERL_NIF_TERM t = marshal_ret(msg_env, (effi_tid)cb->arg_tids[i], args[i]);
        arg_list = enif_make_list_cell(msg_env, t, arg_list);
    }

    /* CbId is the raw pointer as uint64 — used by callback_return to find us */
    uint64_t cb_id = (uint64_t)(uintptr_t)cb;
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env,
        am_effi_callback,
        enif_make_uint64(msg_env, cb_id),
        arg_list);

    /* Lock, mark waiting, send message */
    pthread_mutex_lock(&cb->lock);
    cb->waiting = 1;
    memset(cb->ret_buf, 0, sizeof(cb->ret_buf));

    /* enif_send with NULL env is valid from non-scheduler threads */
    enif_send(NULL, &cb->server_pid, msg_env, msg);
    enif_free_env(msg_env);

    /* Block until callback_return signals us */
    while (cb->waiting)
        pthread_cond_wait(&cb->cond, &cb->lock);

    /* Copy return value into C's return buffer */
    size_t rsz = tid_size((effi_tid)cb->ret_tid);
    if (rsz > 0) memcpy(ret, cb->ret_buf, rsz);

    pthread_mutex_unlock(&cb->lock);
}

/* =========================================================
 * NIF: callback_new/3  (regular scheduler — setup only)
 *   callback_new(RetType, [ArgType], ServerPid)
 *       -> {ok, {CbHandle, FuncPtr}} | {error, Reason}
 * ========================================================= */
static ERL_NIF_TERM nif_callback_new(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    effi_tid ret_tid;
    ErlNifPid pid;
    effi_cb_t *cb = NULL;
    effi_ptr_t *ptr_res = NULL;
    unsigned nargs = 0;
    ERL_NIF_TERM list, head, tail;

    if (argc != 3) return enif_make_badarg(env);

    ret_tid = atom_to_tid(argv[0]);
    if (ret_tid == T_UNKNOWN) return enif_make_badarg(env);
    if (!enif_get_local_pid(env, argv[2], &pid)) return enif_make_badarg(env);

    list = argv[1];
    { ERL_NIF_TERM t = list;
      while (enif_get_list_cell(env, t, &head, &tail)) { nargs++; t = tail; }
      if (!enif_is_empty_list(env, t)) return enif_make_badarg(env); }

    cb = enif_alloc_resource(g_cb_rtype, sizeof(effi_cb_t));
    if (!cb) return enif_make_tuple2(env, am_error, am_alloc_failed);
    memset(cb, 0, sizeof(effi_cb_t));

    cb->ret_tid    = (int)ret_tid;
    cb->nargs      = nargs;
    cb->server_pid = pid;
    pthread_mutex_init(&cb->lock, NULL);
    pthread_cond_init(&cb->cond, NULL);

    cb->arg_types = nargs ? malloc(nargs * sizeof(ffi_type *)) : NULL;
    cb->arg_tids  = nargs ? malloc(nargs * sizeof(int))        : NULL;

    /* Parse arg types */
    { unsigned i = 0; ERL_NIF_TERM t = list;
      while (enif_get_list_cell(env, t, &head, &tail)) {
          effi_tid tid = atom_to_tid(head);
          if (tid == T_UNKNOWN || tid == T_VOID) goto fail;
          cb->arg_tids[i]  = (int)tid;
          cb->arg_types[i] = tid_to_ffi(tid);
          i++; t = tail;
      }
    }

    /* Prepare CIF */
    { ffi_status st = ffi_prep_cif(&cb->cif, FFI_DEFAULT_ABI, nargs,
                                    tid_to_ffi(ret_tid),
                                    nargs ? cb->arg_types : NULL);
      if (st != FFI_OK) goto fail; }

    /* Allocate libffi closure (executable memory) */
    cb->closure = ffi_closure_alloc(sizeof(ffi_closure), &cb->code_ptr);
    if (!cb->closure) goto fail;

    { ffi_status st = ffi_prep_closure_loc(cb->closure, &cb->cif,
                                            callback_trampoline, cb,
                                            cb->code_ptr);
      if (st != FFI_OK) goto fail; }

    /*
     * Build FuncPtr resource.
     * The ptr_res->parent = cb keeps the effi_cb_t alive as long as
     * the FuncPtr resource is alive (ptr_dtor calls enif_release_resource).
     */
    ptr_res = enif_alloc_resource(g_ptr_rtype, sizeof(effi_ptr_t));
    if (!ptr_res) goto fail;
    ptr_res->ptr    = cb->code_ptr;
    ptr_res->owned  = 0;
    ptr_res->size   = 0;
    ptr_res->parent = cb;
    enif_keep_resource(cb);   /* bump ref count for the parent link */

    { ERL_NIF_TERM cb_term  = enif_make_resource(env, cb);
      ERL_NIF_TERM ptr_term = enif_make_resource(env, ptr_res);
      enif_release_resource(cb);
      enif_release_resource(ptr_res);
      return enif_make_tuple2(env, am_ok,
                 enif_make_tuple2(env, cb_term, ptr_term));
    }

fail:
    if (ptr_res) enif_release_resource(ptr_res);
    if (cb) {
        if (cb->closure) ffi_closure_free(cb->closure);
        free(cb->arg_types); free(cb->arg_tids);
        pthread_mutex_destroy(&cb->lock);
        pthread_cond_destroy(&cb->cond);
        enif_release_resource(cb);
    }
    return enif_make_tuple2(env, am_error, am_alloc_failed);
}

/* =========================================================
 * NIF: callback_return/2
 *   callback_return(CbId :: uint64, RetVal) -> ok
 *   Called by the Erlang callback server to unblock the C trampoline.
 * ========================================================= */
static ERL_NIF_TERM nif_callback_return(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    ErlNifUInt64 cb_id;
    effi_cb_t *cb;
    char *str_buf = NULL;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[0], &cb_id)) return enif_make_badarg(env);

    cb = (effi_cb_t *)(uintptr_t)cb_id;

    pthread_mutex_lock(&cb->lock);

    memset(cb->ret_buf, 0, sizeof(cb->ret_buf));
    /* Ignore marshal errors — just leave ret_buf zeroed (safe default) */
    marshal_arg(env, (effi_tid)cb->ret_tid, argv[1], cb->ret_buf, &str_buf);
    if (str_buf) free(str_buf);

    cb->waiting = 0;
    pthread_cond_signal(&cb->cond);
    pthread_mutex_unlock(&cb->lock);

    return am_ok;
}

/* =========================================================
 * NIF table
 * ========================================================= */
static ErlNifFunc nif_funcs[] = {
    {"lib_open",          1, nif_lib_open,          0},
    {"call",              4, nif_call,               ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"call_va",           5, nif_call_va,            ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"mem_alloc",         1, nif_mem_alloc,          0},
    {"mem_free",          1, nif_mem_free,           0},
    {"mem_read",          2, nif_mem_read,           0},
    {"mem_write",         3, nif_mem_write,          0},
    {"mem_read_bytes",    2, nif_mem_read_bytes,     0},
    {"mem_write_bytes",   2, nif_mem_write_bytes,    0},
    {"ptr_add",           2, nif_ptr_add,            0},
    {"ptr_null",          0, nif_ptr_null,           0},
    {"ptr_is_null",       1, nif_ptr_is_null,        0},
    {"type_size",         1, nif_type_size,          0},
    {"callback_new",      3, nif_callback_new,       0},
    {"callback_return",   2, nif_callback_return,    0},
};

/* =========================================================
 * on_load / on_upgrade
 * ========================================================= */
static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv; (void)info;

    init_atoms(env);

    g_lib_rtype = enif_open_resource_type(env, NULL, "effi_lib", lib_dtor,
                      ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (!g_lib_rtype) return -1;

    g_ptr_rtype = enif_open_resource_type(env, NULL, "effi_ptr", ptr_dtor,
                      ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (!g_ptr_rtype) return -1;

    g_cb_rtype  = enif_open_resource_type(env, NULL, "effi_cb",  cb_dtor,
                      ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (!g_cb_rtype) return -1;

    return 0;
}

static int on_upgrade(ErlNifEnv *env, void **priv, void **old_priv,
                      ERL_NIF_TERM info) {
    (void)old_priv;
    return on_load(env, priv, info);
}

ERL_NIF_INIT(effi_nif, nif_funcs, on_load, NULL, on_upgrade, NULL)
