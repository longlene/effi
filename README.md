# cffi

Erlang C Foreign Function Interface — call C library functions from Erlang
at runtime, without writing C bindings or NIFs by hand.

Inspired by Common Lisp's CFFI and Python's `ctypes`/`cffi`.

---

## Features

- **ABI mode (NIF)** — zero-copy calls via libffi in a NIF; fastest path
- **Port safe mode** — C code runs in a separate OS process; a crash cannot
  kill the BEAM VM
- **Rich type system** — structs, unions, enums, typedefs, arrays, nested types
- **C→Erlang callbacks** — pass Erlang closures as C function pointers
  (`qsort`, event hooks, …)
- **Variadic functions** — call `printf`/`snprintf`/… with `call_va/5`
- **Parse transform** — declare C bindings as module attributes, get typed
  wrappers generated at compile time

---

## Quick start

### Prerequisites

```
libffi-dev
```

### Build

```sh
rebar3 compile
```

This compiles both `priv/cffi_nif.so` (via the `pc` plugin) and
`priv/cffi_port` (via `make`).

### Basic call

```erlang
{ok, Lib} = cffi:load("libm.so.6"),
{ok, 2.0} = cffi:call(Lib, "sqrt", double, [{double, 4.0}]),
{ok, 8.0} = cffi:call(Lib, "pow",  double, [{double, 2.0}, {double, 3.0}]).
```

---

## API reference

### Type specs

| Erlang atom | C type |
|-------------|--------|
| `void`      | `void` |
| `bool`      | `_Bool` |
| `int8`      | `int8_t` |
| `uint8`     | `uint8_t` |
| `int16`     | `int16_t` |
| `uint16`    | `uint16_t` |
| `int32`     | `int32_t` |
| `uint32`    | `uint32_t` |
| `int64`     | `int64_t` |
| `uint64`    | `uint64_t` |
| `float`     | `float` |
| `double`    | `double` |
| `pointer`   | `void *` |
| `string`    | `const char *` (null-terminated; encoded as binary on the Erlang side) |

Named registered types (structs, unions, enums, typedefs) can be used
anywhere a type spec is expected.

### `cffi` — NIF mode

```erlang
%% Load a shared library.
{ok, Lib} = cffi:load("libm.so.6").

%% Call a C function.
{ok, Val} = cffi:call(Lib, "func_name", RetType, [{ArgType, ArgVal}, ...]).

%% Call a variadic C function (NFixed = number of fixed arguments).
{ok, N} = cffi:call_va(Lib, "snprintf", int32, 3,
              [{pointer, Buf}, {uint64, BufSize}, {string, "%d"}, {int32, 42}]).

%% Allocate C memory (zeroed).
Ptr = cffi:alloc(Bytes).
Ptr = cffi:alloc_type(TypeAtom).            %% sizeof(Type) bytes
Ptr = cffi:alloc_type(TypeAtom, Count).     %% Count × sizeof(Type) bytes
Ptr = cffi:alloc_struct(StructName).

%% Free C memory.
ok  = cffi:free(Ptr).

%% Read / write a typed value at a pointer.
Val = cffi:read(Ptr, TypeSpec).
ok  = cffi:write(Ptr, TypeSpec, Value).

%% Raw byte I/O.
Bin = cffi:read_bytes(Ptr, Size).
ok  = cffi:write_bytes(Ptr, Binary).

%% Pointer arithmetic.
Ptr2 = cffi:ptr_add(Ptr, ByteOffset).
Null = cffi:null().
true = cffi:is_null(Null).

%% Scoped allocation (pointer freed on exit, even on exception).
Result = cffi:with_alloc(Bytes, fun(Ptr) -> ... end).
Result = cffi:with_alloc(TypeAtom, Count, fun(Ptr) -> ... end).
```

### Type system (`cffi_type` / `cffi`)

```erlang
%% Define a C struct (fields laid out per System V AMD64 ABI).
cffi:defcstruct(point, [{x, double}, {y, double}]).

%% Define a C union.
cffi:defcunion(int_or_float, [{i, int32}, {f, float}]).

%% Define an enum (auto-numbered from 0, or explicit values).
cffi:defcenum(color, [red, green, blue]).
cffi:defcenum(errno_t, [{ok, 0}, {eperm, 1}, {enoent, 2}]).

%% typedef alias.
cffi:defctype(size_t, uint64).
cffi:defctype(my_double, double).

%% Introspect.
16 = cffi:type_size(point).   %% 2 × 8
8  = cffi:align_of(point).

%% Struct field access.
FPtr = cffi:field_ptr(Ptr, point, x).
1.5  = cffi:struct_read(Ptr, point, x).
ok   = cffi:struct_write(Ptr, point, y, 2.5).
#{x := 1.5, y := 2.5} = cffi:struct_to_map(Ptr, point).
ok   = cffi:map_to_struct(Ptr, point, #{x => 0.0, y => 1.0}).

%% Array element access.
Ptr2 = cffi:array_ptr(Ptr, int32, 3).        %% pointer to element 3
42   = cffi:array_read(Ptr, int32, 0).
ok   = cffi:array_write(Ptr, int32, 0, 42).
```

### C→Erlang callbacks (`cffi_callback`)

```erlang
%% Create a C-callable function pointer backed by an Erlang fun.
{ok, Cb} = cffi_callback:new(RetType, [ArgType, ...], fun(A, B, ...) -> ... end).

%% Extract the C function pointer (pass to cffi:call as {pointer, FnPtr}).
FnPtr = cffi_callback:func_ptr(Cb).

%% Free when no longer needed (do not free while C code may still call it).
ok = cffi_callback:free(Cb).
```

**Example — `qsort` with an Erlang comparator:**

```erlang
{ok, Libc} = cffi:load("libc.so.6"),
Arr = cffi:alloc_type(int32, 5),
%% ... fill array ...

{ok, Cb} = cffi_callback:new(int32, [pointer, pointer],
    fun(PA, PB) ->
        A = cffi:read(PA, int32), B = cffi:read(PB, int32),
        if A < B -> -1; A > B -> 1; true -> 0 end
    end),

{ok, ok} = cffi:call(Libc, "qsort", void,
               [{pointer, Arr}, {uint64, 5}, {uint64, 4},
                {pointer, cffi_callback:func_ptr(Cb)}]),

cffi_callback:free(Cb),
cffi:free(Arr).
```

**Notes:**
- Each closure instance is not re-entrant (do not invoke it from two C threads simultaneously).
- The callback server process is linked to the spawning process; it dies when the spawning process dies.
- Errors in the Erlang fun are caught; the C call continues with return value `0`.

### Port safe mode (`cffi_port`)

The port mode API mirrors `cffi` exactly. A crash in the C library terminates the port subprocess but leaves the BEAM VM alive.

```erlang
%% Load — starts a dedicated OS subprocess.
{ok, Lib} = cffi_port:load("libm.so.6").

%% Same call / alloc / read / write / free / ptr_add / struct / array API.
{ok, 2.0} = cffi_port:call(Lib, "sqrt", double, [{double, 4.0}]).
{ok, N}   = cffi_port:call_va(Lib, "snprintf", int32, 3, [...]).

Ptr = cffi_port:alloc(Lib, 8).    %% NB: takes Lib, not just bytes
3.14 = cffi_port:read(Ptr, double).
ok   = cffi_port:write(Ptr, double, 3.14).
P2   = cffi_port:ptr_add(Ptr, 4). %% returns {port_ptr, Pid, Addr}

%% Explicit close (or the subprocess exits with the gen_server).
ok = cffi_port:close(Lib).
```

**Differences from NIF mode:**

| | NIF mode | Port mode |
|---|---|---|
| Crash safety | C crash kills VM | C crash kills subprocess only |
| Speed | Fast (in-process) | Slower (inter-process RPC) |
| Pointers | NIF resource (`reference()`) | `{port_ptr, Pid, Addr}` tuple |
| `alloc` | `cffi:alloc(Bytes)` | `cffi_port:alloc(Lib, Bytes)` |
| Callbacks | `cffi_callback:new/3` | Not supported |

### Parse transform (`cffi_transform`)

Declare C bindings at the module level; the transform generates typed wrapper functions at compile time.

```erlang
-module(my_math).
-compile({parse_transform, cffi_transform}).

-cffi_lib("libm.so.6").
-cffi_fun({sqrt,  double, [double]}).
-cffi_fun({pow,   double, [double, double]}).
%% Different Erlang name / C symbol:
-cffi_fun({{cbrt_val, "cbrt"}, double, [double]}).
```

This generates:

```erlang
sqrt(X)       -> case cffi:call('$cffi_lib$'(), "sqrt",  double, [{double,X}]) of ...
pow(X, Y)     -> case cffi:call('$cffi_lib$'(), "pow",   double, [...]) of ...
cbrt_val(X)   -> case cffi:call('$cffi_lib$'(), "cbrt",  double, [{double,X}]) of ...
```

The library is loaded lazily on first call and cached via `persistent_term`.

---

## Variadic functions

Use `call_va/5` whenever the C function takes `...`:

```erlang
{ok, Lib} = cffi:load("libc.so.6"),
Buf = cffi:alloc(64),

%% snprintf(buf, 64, "%d + %d = %d", 1, 2, 3)
{ok, 7} = cffi:call_va(Lib, "snprintf", int32, 3,
              [{pointer, Buf}, {uint64, 64}, {string, "%d + %d = %d"},
               {int32, 1}, {int32, 2}, {int32, 3}]),

cffi:read_bytes(Buf, 7).   %% <<"1 + 2 = 3">> (minus null)
```

`NFixed` (third integer argument) is the number of fixed parameters before `...`.
For `snprintf` that is `3` (buf, size, fmt).

**C default argument promotions** are applied automatically to variadic arguments:
`float` arguments are promoted to `double` as required by the C standard.

Port mode uses the identical `cffi_port:call_va/5` signature.

---

## Testing

```sh
rebar3 ct
```

| Suite | Cases | Coverage |
|-------|-------|----------|
| `cffi_nif_SUITE` | 15 | load, call, void return, all primitive types, ptr arithmetic, bytes I/O, typedef, enum, struct, union, nested struct, arrays, scoped alloc, callbacks, varargs |
| `cffi_port_SUITE` | 6 | load/close, call, alloc/rw, struct via ptr_add, array, crash isolation |
| `cffi_va_SUITE` | 7 | NIF varargs (int/float/string/multi), port varargs (int/float/string) |

---

## Architecture

```
cffi.erl              ← public API, type resolution, NIF mode
cffi_port.erl         ← public API, port safe mode (gen_server)
cffi_type.erl         ← type registry (ETS), C layout engine
cffi_callback.erl     ← C→Erlang callback server
cffi_transform.erl    ← parse transform
cffi_nif.erl          ← NIF stub (loads priv/cffi_nif.so)

c_src/cffi_nif.c      ← NIF: libffi dispatch, resource GC, callbacks
c_src/cffi_port.c     ← Port executable: same ops over stdin/stdout
```

The ETS type registry (`cffi_type_registry`) is created lazily on first use.
It is a `public` named table; ownership follows the process that first calls
`defcstruct`/`defcenum`/`defctype`.  In long-running applications, define
your types in a supervisor `init` or application `start` callback so the
table owner is a persistent process.

---

## Limitations

- **Callbacks in port mode** — not yet implemented (requires a duplex protocol).
- **Variadic callbacks** — `cffi_callback` does not support variadic C signatures.
- **Windows** — not tested; the Makefile and rebar port_env only cover Linux/macOS.
- **Closures are not re-entrant** — each `cffi_callback` closure instance serialises calls through a single Erlang process.
