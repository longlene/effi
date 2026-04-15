# effi

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

This compiles both `priv/effi_nif.so` (via the `pc` plugin) and
`priv/effi_port` (via `make`).

### Basic call

```erlang
{ok, Lib} = effi:load("libm.so.6"),
{ok, 2.0} = effi:call(Lib, "sqrt", double, [{double, 4.0}]),
{ok, 8.0} = effi:call(Lib, "pow",  double, [{double, 2.0}, {double, 3.0}]).
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

### `effi` — NIF mode

```erlang
%% Load a shared library.
{ok, Lib} = effi:load("libm.so.6").

%% Call a C function.
{ok, Val} = effi:call(Lib, "func_name", RetType, [{ArgType, ArgVal}, ...]).

%% Call a variadic C function (NFixed = number of fixed arguments).
{ok, N} = effi:call_va(Lib, "snprintf", int32, 3,
              [{pointer, Buf}, {uint64, BufSize}, {string, "%d"}, {int32, 42}]).

%% Allocate C memory (zeroed).
Ptr = effi:alloc(Bytes).
Ptr = effi:alloc_type(TypeAtom).            %% sizeof(Type) bytes
Ptr = effi:alloc_type(TypeAtom, Count).     %% Count × sizeof(Type) bytes
Ptr = effi:alloc_struct(StructName).

%% Free C memory.
ok  = effi:free(Ptr).

%% Read / write a typed value at a pointer.
Val = effi:read(Ptr, TypeSpec).
ok  = effi:write(Ptr, TypeSpec, Value).

%% Raw byte I/O.
Bin = effi:read_bytes(Ptr, Size).
ok  = effi:write_bytes(Ptr, Binary).

%% Pointer arithmetic.
Ptr2 = effi:ptr_add(Ptr, ByteOffset).
Null = effi:null().
true = effi:is_null(Null).

%% Scoped allocation (pointer freed on exit, even on exception).
Result = effi:with_alloc(Bytes, fun(Ptr) -> ... end).
Result = effi:with_alloc(TypeAtom, Count, fun(Ptr) -> ... end).
```

### Type system (`effi_type` / `effi`)

```erlang
%% Define a C struct (fields laid out per System V AMD64 ABI).
effi:defcstruct(point, [{x, double}, {y, double}]).

%% Define a C union.
effi:defcunion(int_or_float, [{i, int32}, {f, float}]).

%% Define an enum (auto-numbered from 0, or explicit values).
effi:defcenum(color, [red, green, blue]).
effi:defcenum(errno_t, [{ok, 0}, {eperm, 1}, {enoent, 2}]).

%% typedef alias.
effi:defctype(size_t, uint64).
effi:defctype(my_double, double).

%% Introspect.
16 = effi:type_size(point).   %% 2 × 8
8  = effi:align_of(point).

%% Struct field access.
FPtr = effi:field_ptr(Ptr, point, x).
1.5  = effi:struct_read(Ptr, point, x).
ok   = effi:struct_write(Ptr, point, y, 2.5).
#{x := 1.5, y := 2.5} = effi:struct_to_map(Ptr, point).
ok   = effi:map_to_struct(Ptr, point, #{x => 0.0, y => 1.0}).

%% Array element access.
Ptr2 = effi:array_ptr(Ptr, int32, 3).        %% pointer to element 3
42   = effi:array_read(Ptr, int32, 0).
ok   = effi:array_write(Ptr, int32, 0, 42).
```

### C→Erlang callbacks (`effi_callback`)

```erlang
%% Create a C-callable function pointer backed by an Erlang fun.
{ok, Cb} = effi_callback:new(RetType, [ArgType, ...], fun(A, B, ...) -> ... end).

%% Extract the C function pointer (pass to effi:call as {pointer, FnPtr}).
FnPtr = effi_callback:func_ptr(Cb).

%% Free when no longer needed (do not free while C code may still call it).
ok = effi_callback:free(Cb).
```

**Example — `qsort` with an Erlang comparator:**

```erlang
{ok, Libc} = effi:load("libc.so.6"),
Arr = effi:alloc_type(int32, 5),
%% ... fill array ...

{ok, Cb} = effi_callback:new(int32, [pointer, pointer],
    fun(PA, PB) ->
        A = effi:read(PA, int32), B = effi:read(PB, int32),
        if A < B -> -1; A > B -> 1; true -> 0 end
    end),

{ok, ok} = effi:call(Libc, "qsort", void,
               [{pointer, Arr}, {uint64, 5}, {uint64, 4},
                {pointer, effi_callback:func_ptr(Cb)}]),

effi_callback:free(Cb),
effi:free(Arr).
```

**Notes:**
- Each closure instance is not re-entrant (do not invoke it from two C threads simultaneously).
- The callback server process is linked to the spawning process; it dies when the spawning process dies.
- Errors in the Erlang fun are caught; the C call continues with return value `0`.

### Port safe mode (`effi_port`)

The port mode API mirrors `effi` exactly. A crash in the C library terminates the port subprocess but leaves the BEAM VM alive.

```erlang
%% Load — starts a dedicated OS subprocess.
{ok, Lib} = effi_port:load("libm.so.6").

%% Same call / alloc / read / write / free / ptr_add / struct / array API.
{ok, 2.0} = effi_port:call(Lib, "sqrt", double, [{double, 4.0}]).
{ok, N}   = effi_port:call_va(Lib, "snprintf", int32, 3, [...]).

Ptr = effi_port:alloc(Lib, 8).    %% NB: takes Lib, not just bytes
3.14 = effi_port:read(Ptr, double).
ok   = effi_port:write(Ptr, double, 3.14).
P2   = effi_port:ptr_add(Ptr, 4). %% returns {port_ptr, Pid, Addr}

%% Explicit close (or the subprocess exits with the gen_server).
ok = effi_port:close(Lib).
```

**Differences from NIF mode:**

| | NIF mode | Port mode |
|---|---|---|
| Crash safety | C crash kills VM | C crash kills subprocess only |
| Speed | Fast (in-process) | Slower (inter-process RPC) |
| Pointers | NIF resource (`reference()`) | `{port_ptr, Pid, Addr}` tuple |
| `alloc` | `effi:alloc(Bytes)` | `effi_port:alloc(Lib, Bytes)` |
| Callbacks | `effi_callback:new/3` | Not supported |

### Parse transform (`effi_transform`)

Declare C bindings at the module level; the transform generates typed wrapper functions at compile time.

```erlang
-module(my_math).
-compile({parse_transform, effi_transform}).

-effi_lib("libm.so.6").
-effi_fun({sqrt,  double, [double]}).
-effi_fun({pow,   double, [double, double]}).
%% Different Erlang name / C symbol:
-effi_fun({{cbrt_val, "cbrt"}, double, [double]}).
```

This generates:

```erlang
sqrt(X)       -> case effi:call('$effi_lib$'(), "sqrt",  double, [{double,X}]) of ...
pow(X, Y)     -> case effi:call('$effi_lib$'(), "pow",   double, [...]) of ...
cbrt_val(X)   -> case effi:call('$effi_lib$'(), "cbrt",  double, [{double,X}]) of ...
```

The library is loaded lazily on first call and cached via `persistent_term`.

---

## Variadic functions

Use `call_va/5` whenever the C function takes `...`:

```erlang
{ok, Lib} = effi:load("libc.so.6"),
Buf = effi:alloc(64),

%% snprintf(buf, 64, "%d + %d = %d", 1, 2, 3)
{ok, 7} = effi:call_va(Lib, "snprintf", int32, 3,
              [{pointer, Buf}, {uint64, 64}, {string, "%d + %d = %d"},
               {int32, 1}, {int32, 2}, {int32, 3}]),

effi:read_bytes(Buf, 7).   %% <<"1 + 2 = 3">> (minus null)
```

`NFixed` (third integer argument) is the number of fixed parameters before `...`.
For `snprintf` that is `3` (buf, size, fmt).

**C default argument promotions** are applied automatically to variadic arguments:
`float` arguments are promoted to `double` as required by the C standard.

Port mode uses the identical `effi_port:call_va/5` signature.

---

## Testing

```sh
rebar3 ct
```

| Suite | Cases | Coverage |
|-------|-------|----------|
| `effi_nif_SUITE` | 15 | load, call, void return, all primitive types, ptr arithmetic, bytes I/O, typedef, enum, struct, union, nested struct, arrays, scoped alloc, callbacks, varargs |
| `effi_port_SUITE` | 6 | load/close, call, alloc/rw, struct via ptr_add, array, crash isolation |
| `effi_va_SUITE` | 7 | NIF varargs (int/float/string/multi), port varargs (int/float/string) |

---

## Architecture

```
effi.erl              ← public API, type resolution, NIF mode
effi_port.erl         ← public API, port safe mode (gen_server)
effi_type.erl         ← type registry (ETS), C layout engine
effi_callback.erl     ← C→Erlang callback server
effi_transform.erl    ← parse transform
effi_nif.erl          ← NIF stub (loads priv/effi_nif.so)

c_src/effi_nif.c      ← NIF: libffi dispatch, resource GC, callbacks
c_src/effi_port.c     ← Port executable: same ops over stdin/stdout
```

The ETS type registry (`effi_type_registry`) is created lazily on first use.
It is a `public` named table; ownership follows the process that first calls
`defcstruct`/`defcenum`/`defctype`.  In long-running applications, define
your types in a supervisor `init` or application `start` callback so the
table owner is a persistent process.

---

## Limitations

- **Callbacks in port mode** — not yet implemented (requires a duplex protocol).
- **Variadic callbacks** — `effi_callback` does not support variadic C signatures.
- **Windows** — not tested; the Makefile and rebar port_env only cover Linux/macOS.
- **Closures are not re-entrant** — each `effi_callback` closure instance serialises calls through a single Erlang process.
