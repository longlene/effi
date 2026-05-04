%% cffi_callback.erl — C→Erlang callback support via libffi closures.
%%
%% Usage:
%%
%%   %% Create a callback: C sees a (int32, int32) -> int32 function pointer.
%%   {ok, Cb} = cffi_callback:new(int32, [pointer, pointer],
%%       fun(A, B) ->
%%           VA = cffi:read(A, int32),
%%           VB = cffi:read(B, int32),
%%           if VA < VB -> -1; VA > VB -> 1; true -> 0 end
%%       end),
%%
%%   FuncPtr = cffi_callback:func_ptr(Cb),
%%
%%   cffi:call(Lib, "qsort", void, [
%%       {pointer, ArrayPtr},
%%       {int32,   Count},
%%       {int32,   ElemSize},
%%       {pointer, FuncPtr}
%%   ]),
%%
%%   cffi_callback:free(Cb).
%%
%% Notes:
%%   - Callbacks are NOT re-entrant per closure instance.
%%   - The server process is linked to the calling process.
%%   - Errors in Fun default to returning 0; the call continues.
%%   - Do not call free/1 while C code may still invoke the closure.

-module(cffi_callback).

-export([new/3, func_ptr/1, free/1]).

-opaque callback() :: {CbHandle :: reference(), FuncPtr :: reference(), ServerPid :: pid()}.
-export_type([callback/0]).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

%% new(RetType, ArgTypes, Fun) -> {ok, callback()} | {error, Reason}
%%
%% RetType  : type atom for the C return type
%% ArgTypes : list of type atoms for the C argument types
%% Fun      : fun/N where N = length(ArgTypes); receives Erlang-marshaled args
-spec new(atom(), [atom()], function()) -> {ok, callback()} | {error, term()}.
new(RetType, ArgTypes, Fun) ->
    Parent = self(),
    %% Spawn a linked server; link ensures it dies when the caller dies.
    ServerPid = spawn_link(fun() -> server_init(Fun, Parent) end),
    case cffi_nif:callback_new(RetType, ArgTypes, ServerPid) of
        {ok, {CbHandle, FuncPtr}} ->
            {ok, {CbHandle, FuncPtr, ServerPid}};
        {error, _} = Err ->
            exit(ServerPid, kill),
            Err
    end.

%% func_ptr(Cb) -> cffi_ptr()
%% Extract the function pointer resource for passing to C via cffi:call/4.
-spec func_ptr(callback()) -> reference().
func_ptr({_Handle, FuncPtr, _Pid}) -> FuncPtr.

%% free(Cb) -> ok
%% Stop the server process and release the closure.
%% The underlying C resource is GC'd when both CbHandle and FuncPtr go away.
-spec free(callback()) -> ok.
free({_Handle, _FuncPtr, ServerPid}) ->
    ServerPid ! stop,
    ok.

%% -------------------------------------------------------------------------
%% Internal: callback server process
%%
%% Receives  : {cffi_callback, CbId, ArgList}
%% Replies   : cffi_nif:callback_return(CbId, RetVal)  (unblocks C trampoline)
%% -------------------------------------------------------------------------

server_init(Fun, _Parent) ->
    server_loop(Fun).

server_loop(Fun) ->
    receive
        {cffi_callback, CbId, Args} ->
            Ret = try
                erlang:apply(Fun, Args)
            catch
                Class:Reason ->
                    error_logger:warning_msg(
                        "cffi_callback: Fun raised ~p:~p, returning 0~n",
                        [Class, Reason]),
                    0
            end,
            cffi_nif:callback_return(CbId, Ret),
            server_loop(Fun);
        stop ->
            ok
    end.
