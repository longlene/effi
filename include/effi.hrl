%% effi.hrl - Type atom shorthands (optional convenience, all atoms work directly)

-ifndef(EFFI_HRL).
-define(EFFI_HRL, true).

%% Primitive C types
-define(void,    void).
-define(int8,    int8).
-define(uint8,   uint8).
-define(int16,   int16).
-define(uint16,  uint16).
-define(int32,   int32).
-define(uint32,  uint32).
-define(int64,   int64).
-define(uint64,  uint64).
-define(float,   float).
-define(double,  double).
-define(ptr,     pointer).
-define(string,  string).   %% char* <-> binary()

%% Convenience: call with no args
-define(effi_call(Lib, Func, Ret), effi:call(Lib, Func, Ret, [])).

-endif.
