%% Copyright (c) 2020 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : luerl_heap.erl
%% Author  : Robert Virding
%% Purpose : Implements the heap section of the Luerl state.
%%
%% Note that here we only handle the data in the heap and never call
%% anything in either Luerl or Erlang. Those cases where this could
%% happen we return values informing the caller to do it. For example
%% in the set_table_key and get_table_key functions.

-module(luerl_heap).

-include("luerl.hrl").

-export([init/0]).

%% External interface.
-export([alloc_table/1,alloc_table/2,free_table/2,
         get_table/2,set_table/3,upd_table/3,
         get_global_key/2,set_global_key/3,
         get_table_key/3,set_table_key/4,
         raw_get_table_key/3,raw_set_table_key/4,
         alloc_userdata/2,alloc_userdata/3,get_userdata/2,set_userdata/3,
         alloc_funcdef/2,get_funcdef/2,set_funcdef/3,
         alloc_environment/2,get_env_var/3,set_env_var/4,
         get_metamethod/3,get_metamethod/4,
         get_metatable/2, set_metatable/3
        ]).

-import(luerl_lib, [lua_error/2,badarg_error/3]).

%% init() -> State
%%
%% Initialise the heap section of the state and return the state.

init() ->
    St0 = #luerl{meta=#meta{},tag=make_ref()},
    init_tables(St0).

init_tables(St) ->
    %% Initialise the table handling.
    Tst = init_tstruct(),
    %% Initialise the environment handling.
    Est = init_tstruct(),
    %% Initialise the userdata handling.
    Ust = init_tstruct(),
    %% Initialise the function def handling.
    Fst = init_tstruct(),
    St#luerl{tabs=Tst,envs=Est,usds=Ust,fncs=Fst}.

%% init_tstruct() -> #tstruct{}.
%% alloc_tstruct(Val, #tstruct{}) -> {Index,#tstruct{}}.
%% set_tstruct(Index, Val, #tstruct{}) -> #tstruct{}.
%% upd_tstruct(Index, UpdFun, #tstruct{}) -> #tstruct{}.
%% del_tstruct(Index, #tstruct{}) -> #tstruct{}.
%%
%%  Functions for accessing tstructs.

init_tstruct() ->
    #tstruct{data=?MAKE_TABLE(),free=[],next=0}.

alloc_tstruct(Val, #tstruct{data=D0,free=[N|Ns]}=Tstr) ->
    D1 = ?SET_TABLE(N, Val, D0),
    {N,Tstr#tstruct{data=D1,free=Ns}};
alloc_tstruct(Val, #tstruct{data=D0,free=[],next=N}=Tstr) ->
    D1 = ?SET_TABLE(N, Val, D0),
    {N,Tstr#tstruct{data=D1,next=N+1}}.

set_tstruct(N, Val, #tstruct{data=D0}=Tstr) ->
    D1 = ?SET_TABLE(N, Val, D0),
    Tstr#tstruct{data=D1}.

upd_tstruct(N, Upd, #tstruct{data=D0}=Tstr) ->
    D1 = ?UPD_TABLE(N, Upd, D0),
    Tstr#tstruct{data=D1}.

del_tstruct(N, #tstruct{data=D0,free=Ns}=Tstr) ->
    D1 = ?DEL_TABLE(N, D0),
    Tstr#tstruct{data=D1,free=[N|Ns]}.

-compile({inline,[get_tstruct/2]}).             %Such a simple function
get_tstruct(N, Tstr) ->
    ?GET_TABLE(N, Tstr#tstruct.data).

%% alloc_table(State) -> {Tref,State}
%%
%% Allocate an empty table.

alloc_table(St) -> alloc_table([], St).

%% alloc_table(InitialTable, State) -> {Tref,State}
%%
%% The InitialTable is [{Key,Value}], there is no longer any need
%% to have it as an orddict.

alloc_table(Itab, #luerl{tabs=Tst0}=St) ->
    Tab = create_table(Itab),
    {N,Tst1} = alloc_tstruct(Tab, Tst0),
    {#tref{i=N},St#luerl{tabs=Tst1}}.

create_table(Itab) ->
    D0 = ttdict:new(),
    A0 = array:new([{default,nil}]),            %Arrays with 'nil' as default
    Init = fun ({_,nil}, {D,A}) -> {D,A};       %Ignore nil values
               ({K,V}, {D,A}) when is_integer(K), K >= 1 ->
                   {D,array:set(K, V, A)};
               ({K,V}, {D,A}) when is_float(K) ->
                   case ?IS_FLOAT_INT(K, I) of
                       true when I >= 1 -> {D,array:set(I, V, A)};
                       _NegFalse -> {ttdict:store(K, V, D),A}
                   end;
               ({K,V}, {D,A}) -> {ttdict:store(K, V, D),A}
           end,
    {D1,A1} = lists:foldl(Init, {D0,A0}, Itab),
    #table{a=A1,d=D1,meta=nil}.

%% free_table(Tref, State) -> State
%%
%% Delete a table freeing its space.

free_table(#tref{i=N}, #luerl{tabs=Tst0}=St) ->
    Tst1 = del_tstruct(N, Tst0),
    St#luerl{tabs=Tst1}.

%% get_table(Tref, State) -> Table
%%
%% Get the table referred to by Tref.

get_table(#tref{i=N}, #luerl{tabs=Tst}) ->
    get_tstruct(N, Tst).

%% set_table(Tref, Table, State) -> State
%%
%% Set a new table at the location referred to by Tref
%% overwriting the existing one.

set_table(#tref{i=N}, Tab, #luerl{tabs=Tst0}=St) ->
    Tst1 = set_tstruct(N, Tab, Tst0),
    St#luerl{tabs=Tst1}.

%% upd_table(Tref, Fun, State) -> State
%%
%% Update the table at the location referred to by Tref.

upd_table(#tref{i=N}, Upd, #luerl{tabs=Tst0}=St) ->
    Tst1 = upd_tstruct(N, Upd, Tst0),
    St#luerl{tabs=Tst1}.

%% set_global_key(Key, Value, State) ->
%%     {value,Value,State} | {meta,Method,Args,State} | {error,Error,State}
%%
%% Set a key in the global name table _G to value.

set_global_key(Key, Val, #luerl{g=G}=St) ->
    set_table_key(G, Key, Val, St).

%% get_global_key(Key, State) ->
%%     {value,Value,State} | {meta,Method,Args,State} | {error,Error,State}
%%
%% Get the value of a key in the global name table, _G.

get_global_key(Key, #luerl{g=G}=St) ->
    get_table_key(G, Key, St).
 
%% set_table_key(Table, Key, Val, State) ->
%%     {value,Value,State} | {meta,Method,Args,State} | {error,Error,State}
%%
%% We don't make calls to meta methods or generate errors but
%% return a value indicating this. Setting a value to 'nil' will clear
%% it from the table and the array. We won't add a nil value.

set_table_key(#tref{}=Tref, Key, Val, St) when is_integer(Key), Key >= 1 ->
    set_table_key_int(Tref, Key, Key, Val, St);
set_table_key(#tref{}=Tref, Key, Val, St) when is_float(Key) ->
    case ?IS_FLOAT_INT(Key, I) of
        true when I >= 1 -> set_table_key_int(Tref, Key, I, Val, St);
        _NegFalse -> set_table_key_key(Tref, Key, Val, St)
    end;
set_table_key(Tab, nil=Key, _, St) ->
    {error,{illegal_index,Tab,Key},St};
set_table_key(#tref{}=Tref, Key, Val, St) ->
    set_table_key_key(Tref, Key, Val, St);
set_table_key(Tab, Key, _, St) ->
    {error,{illegal_index,Tab,Key},St}.

set_table_key_key(#tref{i=N}=Tab, Key, Val, #luerl{tabs=Tst0}=St) ->
    Ts0 = Tst0#tstruct.data,
    #table{d=Dict0,meta=Meta}=T = ?GET_TABLE(N, Ts0),
    case ttdict:find(Key, Dict0) of
        {ok,_} ->                               %Key exists
            Dict1 = if Val =:= nil -> ttdict:erase(Key, Dict0);
                       true -> ttdict:store(Key, Val, Dict0)
                    end,
            Ts1 = ?SET_TABLE(N, T#table{d=Dict1}, Ts0),
            Tst1 = Tst0#tstruct{data=Ts1},
            {value,[],St#luerl{tabs=Tst1}};
        error ->                                %Key does not exist
            case get_metamethod_tab(Meta, <<"__newindex">>, Ts0) of
                nil ->
                    %% Only add non-nil value.
                    Dict1 = if Val =:= nil -> Dict0;
                               true -> ttdict:store(Key, Val, Dict0)
                            end,
                    Ts1 = ?SET_TABLE(N, T#table{d=Dict1}, Ts0),
                    Tst1 = Tst0#tstruct{data=Ts1},
                    {value,[],St#luerl{tabs=Tst1}};
                Meth when ?IS_FUNCTION(Meth) ->
                    {meta,Meth,[Tab,Key,Val],St};
                Meth -> set_table_key(Meth, Key, Val, St)
            end
    end.

set_table_key_int(#tref{i=N}=Tab, Key, I, Val, #luerl{tabs=Tst0}=St) ->
    Ts0 = Tst0#tstruct.data,
    #table{a=Arr0,meta=Meta}=T = ?GET_TABLE(N, Ts0),
    case array:get(I, Arr0) of
        nil ->                                  %Key does not exist
            case get_metamethod_tab(Meta, <<"__newindex">>, Ts0) of
                nil ->
                    %% Only add non-nil value, slightly faster (?)
                    Arr1 = if Val =:= nil -> Arr0;
                              true -> array:set(I, Val, Arr0)
                           end,
                    Ts1 = ?SET_TABLE(N, T#table{a=Arr1}, Ts0),
                    Tst1 = Tst0#tstruct{data=Ts1},
                    {value,[],St#luerl{tabs=Tst1}};
                Meth when ?IS_FUNCTION(Meth) ->
                    {meta,Meth,[Tab,Key,Val],St};
                Meth -> set_table_key(Meth, Key, Val, St)
            end;
        _ ->                                    %Key exists
            %% Can do this as 'nil' is default value of array.
            Arr1 = array:set(I, Val, Arr0),
            Ts1 = ?SET_TABLE(N, T#table{a=Arr1}, Ts0),
            Tst1 = Tst0#tstruct{data=Ts1},
            {value,[],St#luerl{tabs=Tst1}}
    end.

%% get_table_key(Table, Key, State) ->
%%     {value,Value,State} | {meta,Method,Args,State} | {error,Error,State}
%%
%% We don't make calls to meta methods or generate errors but
%% return value indicating this.

get_table_key(#tref{}=Tref, Key, St) when is_integer(Key), Key >= 1 ->
    get_table_key_int(Tref, Key, Key, St);
get_table_key(#tref{}=Tref, Key, St) when is_float(Key) ->
    case ?IS_FLOAT_INT(Key, I) of
        true when I >= 1 -> get_table_key_int(Tref, Key, I, St);
        _NegFalse -> get_table_key_key(Tref, Key, St)
    end;
get_table_key(#tref{}=Tref, Key, St) ->
    get_table_key_key(Tref, Key, St);
get_table_key(Tab, Key, St) ->                  %Just find the metamethod
    case get_metamethod(Tab, <<"__index">>, St) of
        nil ->
            {error,{illegal_index,Tab,Key},St};
        Meth when ?IS_FUNCTION(Meth) ->
            {meta,Meth,[Tab,Key],St};
        Meth ->                                 %Recurse down the metatable
            get_table_key(Meth, Key, St)
    end.

get_table_key_key(#tref{i=N}=Tab, Key, #luerl{tabs=#tstruct{data=Ts}}=St) ->
    #table{d=Dict,meta=Meta} = ?GET_TABLE(N, Ts),
    case ttdict:find(Key, Dict) of
        {ok,Val} -> {value,Val,St};
        error ->
            %% Key not present so try metamethod
            get_table_key_metamethod(Tab, Meta, Key, Ts, St)
    end.

get_table_key_int(#tref{i=N}=T, Key, I, #luerl{tabs=#tstruct{data=Ts}}=St) ->
    #table{a=A,meta=Meta} = ?GET_TABLE(N, Ts),  %Get the table.
    case array:get(I, A) of
        nil ->
            %% Key not present so try metamethod
            get_table_key_metamethod(T, Meta, Key, Ts, St);
        Val -> {value,Val,St}
    end.

get_table_key_metamethod(Tab, Meta, Key, Ts, St) ->
    case get_metamethod_tab(Meta, <<"__index">>, Ts) of
        nil -> {value,nil,St};
        Meth when ?IS_FUNCTION(Meth) ->
            {meta,Meth,[Tab,Key],St};
        Meth ->                         %Recurse down the metatable
            get_table_key(Meth, Key, St)
    end.

%% raw_get_table_key(Table, Key, State) -> Value.
%% raw_set_table_key(Table, Key, Value, State) -> State.
%%
%% Get/set key values in tables without metamethods.

raw_get_table_key(#tref{i=N}, Key, #luerl{tabs=Tst})
  when is_integer(Key), Key >= 1 ->
    raw_get_table_key_int(N, Key, Tst);
raw_get_table_key(#tref{i=N}, Key, #luerl{tabs=Tst})
  when is_float(Key) ->
    case ?IS_FLOAT_INT(Key, I) of
        true when I >= 1 ->
            raw_get_table_key_int(N, I, Tst);
        _NegFalse ->
            raw_get_table_key_key(N, Key, Tst)
    end;
raw_get_table_key(#tref{i=N}, Key, #luerl{tabs=Tst}) ->
    raw_get_table_key_key(N, Key, Tst).

raw_get_table_key_key(N, Key, Tst) ->
    #table{d=Dict} = get_tstruct(N, Tst),
    case ttdict:find(Key, Dict) of
        {ok,Val} -> Val;
        error -> nil
    end.

raw_get_table_key_int(N, Key, Tst) ->
    #table{a=Arr} = get_tstruct(N, Tst),
    array:get(Key, Arr).

raw_set_table_key(#tref{}=Tref, Key, Val, #luerl{tabs=Tst0}=St)
  when is_integer(Key), Key >= 1 ->
    Tst1 = raw_set_table_key_int(Tref, Key, Val, Tst0),
    St#luerl{tabs=Tst1};
raw_set_table_key(#tref{}=Tref, Key, Val, #luerl{tabs=Tst0}=St)
  when is_float(Key) ->
    Tst1 = case ?IS_FLOAT_INT(Key, I) of
               true when I >= 1 ->
                   raw_set_table_key_int(Tref, I, Val, Tst0);
               _NegFalse ->
                   raw_set_table_key_key(Tref, Key, Val, Tst0)
           end,
    St#luerl{tabs=Tst1}.

raw_set_table_key_key(#tref{i=N}, Key, Val, Tst0) ->
    Fun = fun (#table{d=Dict0}=Tab) ->
                  Dict1 = if Val =:= nil -> ttdict:erase(Key, Dict0);
                             true -> ttdict:store(Key, Val, Dict0)
                          end,
                  Tab#table{d=Dict1}
          end,
    upd_tstruct(N, Fun, Tst0).

raw_set_table_key_int(#tref{i=N}, Key, Val, Tst0) ->
    Fun = fun (#table{a=Arr0}=Tab) ->
                  %% Default array value is nil.
                  Arr1 = array:set(Key, Val, Arr0),
                  Tab#table{a=Arr1}
          end,
    upd_tstruct(N, Fun, Tst0).

%% alloc_userdata(Data, State) -> {Usdref,State}
%%
%% Allocate userdata with empty metadata.

alloc_userdata(Data, St) ->
    alloc_userdata(Data, nil, St).

%% alloc_userdata(Data, Meta, State) -> {Usdref,State}.
%%
%% Allocate userdata setting its metadata.

alloc_userdata(Data, Meta, #luerl{usds=Ust0}=St) ->
    Ud = #userdata{d=Data,meta=Meta},
    {N,Ust1} = alloc_tstruct(Ud, Ust0),
    {#usdref{i=N},St#luerl{usds=Ust1}}.

%% get_userdata(Usdref, State) -> {UserData,State}
%%
%% Get the userdata data.

get_userdata(#usdref{i=N}, #luerl{usds=Ust}=St) ->
    #userdata{} = Udata = get_tstruct(N, Ust),
    {Udata,St}.

%% set_userdata(Usdref, UserData, State) -> State
%%
%% Set the data in the userdata.

set_userdata(#usdref{i=N}, Data, #luerl{usds=Ust0}=St) ->
    Ust1 = upd_tstruct(N, fun (Ud) -> Ud#userdata{d=Data} end, Ust0),
    St#luerl{usds=Ust1}.

%% make_userdata(Data) -> make_userdata(Data, nil).
%% make_userdata(Data, Meta) -> #userdata{d=Data,meta=Meta}.

%% alloc_funcdef(Def, State) -> {FunRef,State}

alloc_funcdef(Func, #luerl{fncs=Fst0}=St) ->
    {N,Fst1} = alloc_tstruct(Func, Fst0),
    {#funref{i=N},St#luerl{fncs=Fst1}}.

%% get_funcdef(Funref, State) -> {Fdef,State}
%%
%% Get the function data referred to by Fref.

get_funcdef(#funref{i=N}, #luerl{fncs=Fst}=St) ->
    Fdef = get_tstruct(N, Fst),
    {Fdef,St}.

%% set_funcdef(Funref, Fdef, State) -> State.
%%
%% Set the function data referred to by Fref.

set_funcdef(#funref{i=N}, Func, #luerl{fncs=Fst0}=St) ->
    Fst1 = set_tstruct(N, Func, Fst0),
    St#luerl{fncs=Fst1}.

%% get_metamethod(Object1, Object2, Event, State) -> Method | nil
%%
%% Get the metamethod for object(s).

get_metamethod(O1, O2, E, St) ->
    case get_metamethod(O1, E, St) of
        nil -> get_metamethod(O2, E, St);
        M -> M
    end.

get_metamethod(O, E, St) ->
    Meta = get_metatable(O, St),                        %Can be nil
    get_metamethod_tab(Meta, E, St#luerl.tabs#tstruct.data).

get_metamethod_tab(#tref{i=M}, E, Ts) ->
    #table{d=Mdict} = ?GET_TABLE(M, Ts),
    case ttdict:find(E, Mdict) of
        {ok,Mm} -> Mm;
        error -> nil
    end;
get_metamethod_tab(_, _, _) -> nil.             %Other types have no metatables

%% get_metatable(Obj, State) -> MetaTable
%%
%% Get the metatable of an object or its type metatable.

get_metatable(#tref{i=T}, #luerl{tabs=Tst}) ->
    (get_tstruct(T, Tst))#table.meta;
get_metatable(#usdref{i=U}, #luerl{usds=Ust}) ->
    (get_tstruct(U, Ust))#userdata.meta;
get_metatable(nil, #luerl{meta=Meta}) -> Meta#meta.nil;
get_metatable(B, #luerl{meta=Meta}) when is_boolean(B) ->
    Meta#meta.boolean;
get_metatable(N, #luerl{meta=Meta}) when is_number(N) ->
    Meta#meta.number;
get_metatable(S, #luerl{meta=Meta}) when is_binary(S) ->
    Meta#meta.string;
get_metatable(_, _) -> nil.                     %Other types have no metatables

%% set_metatable(Obj, MetaTable, State) -> State
%%
%% Set the metatable of an object or its type metatable.

set_metatable(#tref{i=N}, M, #luerl{tabs=Tst0}=St) ->
    Tst1 = upd_tstruct(N, fun (Tab) -> Tab#table{meta=M} end, Tst0),
    St#luerl{tabs=Tst1};
set_metatable(#usdref{i=N}, M, #luerl{usds=Ust0}=St) ->
    Ust1 = upd_tstruct(N, fun (Ud) -> Ud#userdata{meta=M} end, Ust0),
    St#luerl{usds=Ust1};
set_metatable(nil, M, #luerl{meta=Meta0}=St) ->
    Meta1 = Meta0#meta{nil=M},
    St#luerl{meta=Meta1};
set_metatable(B, M, #luerl{meta=Meta0}=St) when is_boolean(B) ->
    Meta1 = Meta0#meta{boolean=M},
    St#luerl{meta=Meta1};
set_metatable(N, M, #luerl{meta=Meta0}=St) when is_number(N) ->
    Meta1 = Meta0#meta{number=M},
    St#luerl{meta=Meta1};
set_metatable(B, M, #luerl{meta=Meta0}=St) when is_binary(B) ->
    Meta1 = Meta0#meta{string=M},
    St#luerl{meta=Meta1};
set_metatable(_, _, St) ->                      %Do nothing for the rest
    St.

%% alloc_environment(Size, State) -> {Fref,State}
%%
%% Allocate the environment in the environemnt table and return
%% its eref.

alloc_environment(Size, #luerl{envs=Est0}=St) ->
    Fr = erlang:make_tuple(Size, nil),
    {N,Est1} = alloc_tstruct(Fr, Est0),
    {#eref{i=N},St#luerl{envs=Est1}}.

%% get_env_var(Eref, Index, State) -> Value.
%% set_env_var(Eref, Index, Val, State) -> State.

get_env_var(#eref{i=N}, Index, #luerl{envs=Etab}) ->
    element(Index, get_tstruct(N, Etab)).
%%     element(Index, ?GET_TABLE(N, Etab#tstruct.data)).

set_env_var(#eref{i=N}, Index, Val, #luerl{envs=Est0}=St) ->
    Est1 = upd_tstruct(N, fun (Fr) -> setelement(Index, Fr, Val) end, Est0),
    St#luerl{envs=Est1}.