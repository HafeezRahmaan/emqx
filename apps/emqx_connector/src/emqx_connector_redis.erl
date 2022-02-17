%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------
-module(emqx_connector_redis).

-include("emqx_connector.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").

-export([roots/0, fields/1]).

-behaviour(emqx_resource).

%% callbacks of behaviour emqx_resource
-export([ on_start/2
        , on_stop/2
        , on_query/4
        , on_health_check/2
        ]).

-export([do_health_check/1]).

-export([connect/1]).

-export([cmd/3]).

%% redis host don't need parse
-define( REDIS_HOST_OPTIONS
       , #{ host_type => hostname
          , default_port => ?REDIS_DEFAULT_PORT}).


%%=====================================================================
roots() ->
    [ {config, #{type => hoconsc:union(
                  [ hoconsc:ref(?MODULE, cluster)
                  , hoconsc:ref(?MODULE, single)
                  , hoconsc:ref(?MODULE, sentinel)
                  ])}
      }
    ].

fields(single) ->
    [ {server, fun server/1}
    , {redis_type, #{type => hoconsc:enum([single]),
                     default => single}}
    ] ++
    redis_fields() ++
    emqx_connector_schema_lib:ssl_fields();
fields(cluster) ->
    [ {servers, fun servers/1}
    , {redis_type, #{type => hoconsc:enum([cluster]),
                     default => cluster}}
    ] ++
    redis_fields() ++
    emqx_connector_schema_lib:ssl_fields();
fields(sentinel) ->
    [ {servers, fun servers/1}
    , {redis_type, #{type => hoconsc:enum([sentinel]),
                     default => sentinel}}
    , {sentinel, #{type => string()}}
    ] ++
    redis_fields() ++
    emqx_connector_schema_lib:ssl_fields().

server(type) -> emqx_schema:ip_port();
server(nullable) -> false;
server(validator) -> [?NOT_EMPTY("the value of the field 'server' cannot be empty")];
server(converter) -> fun to_server_raw/1;
server(desc) -> ?SERVER_DESC("Redis", integer_to_list(?REDIS_DEFAULT_PORT));
server(_) -> undefined.

servers(type) -> list();
servers(nullable) -> false;
servers(validator) -> [?NOT_EMPTY("the value of the field 'servers' cannot be empty")];
servers(converter) -> fun to_servers_raw/1;
servers(desc) -> ?SERVERS_DESC ++ server(desc);
servers(_) -> undefined.

%% ===================================================================
on_start(InstId, #{redis_type := Type,
                   database := Database,
                   pool_size := PoolSize,
                   auto_reconnect := AutoReconn,
                   ssl := SSL } = Config) ->
    ?SLOG(info, #{msg => "starting_redis_connector",
                  connector => InstId, config => Config}),
    Servers = case Type of
                single -> [{servers, [maps:get(server, Config)]}];
                _ ->[{servers, maps:get(servers, Config)}]
              end,
    Opts = [{pool_size, PoolSize},
            {database, Database},
            {password, maps:get(password, Config, "")},
            {auto_reconnect, reconn_interval(AutoReconn)}
           ] ++ Servers,
    Options = case maps:get(enable, SSL) of
                  true ->
                      [{ssl, true},
                       {ssl_options,
                        emqx_plugin_libs_ssl:save_files_return_opts(SSL, "connectors", InstId)}
                      ];
                  false -> [{ssl, false}]
              end ++ [{sentinel, maps:get(sentinel, Config, undefined)}],
    PoolName = emqx_plugin_libs_pool:pool_name(InstId),
    case Type of
        cluster ->
            case eredis_cluster:start_pool(PoolName, Opts ++ [{options, Options}]) of
                {ok, _}         -> {ok, #{poolname => PoolName, type => Type}};
                {ok, _, _}      -> {ok, #{poolname => PoolName, type => Type}};
                {error, Reason} -> {error, Reason}
            end;
        _ ->
            case emqx_plugin_libs_pool:start_pool(PoolName, ?MODULE, Opts ++ [{options, Options}]) of
                ok              -> {ok, #{poolname => PoolName, type => Type}};
                {error, Reason} -> {error, Reason}
            end
    end.

on_stop(InstId, #{poolname := PoolName}) ->
    ?SLOG(info, #{msg => "stopping_redis_connector",
                  connector => InstId}),
    emqx_plugin_libs_pool:stop_pool(PoolName).

on_query(InstId, {cmd, Command}, AfterCommand, #{poolname := PoolName, type := Type} = State) ->
    ?TRACE("QUERY", "redis_connector_received",
        #{connector => InstId, sql => Command, state => State}),
    Result = case Type of
                 cluster -> eredis_cluster:q(PoolName, Command);
                 _ -> ecpool:pick_and_do(PoolName, {?MODULE, cmd, [Type, Command]}, no_handover)
             end,
    case Result of
        {error, Reason} ->
            ?SLOG(error, #{msg => "redis_connector_do_cmd_query_failed",
                connector => InstId, sql => Command, reason => Reason}),
            emqx_resource:query_failed(AfterCommand);
        _ ->
            emqx_resource:query_success(AfterCommand)
    end,
    Result.

on_health_check(_InstId, #{type := cluster, poolname := PoolName} = State) ->
    Workers = lists:flatten([gen_server:call(PoolPid, get_all_workers) ||
                             PoolPid <- eredis_cluster_monitor:get_all_pools(PoolName)]),
    case length(Workers) > 0 andalso lists:all(
            fun({_, Pid, _, _}) ->
                eredis_cluster_pool_worker:is_connected(Pid) =:= true
            end, Workers) of
        true -> {ok, State};
        false -> {error, health_check_failed, State}
    end;
on_health_check(_InstId, #{poolname := PoolName} = State) ->
    emqx_plugin_libs_pool:health_check(PoolName, fun ?MODULE:do_health_check/1, State).

do_health_check(Conn) ->
    case eredis:q(Conn, ["PING"]) of
        {ok, _} -> true;
        _ -> false
    end.

reconn_interval(true) -> 15;
reconn_interval(false) -> false.

cmd(Conn, cluster, Command) ->
    eredis_cluster:q(Conn, Command);
cmd(Conn, _Type, Command) ->
    eredis:q(Conn, Command).

%% ===================================================================
connect(Opts) ->
    eredis:start_link(Opts).

redis_fields() ->
    [ {pool_size, fun emqx_connector_schema_lib:pool_size/1}
    , {password, fun emqx_connector_schema_lib:password/1}
    , {database, #{type => integer(),
                   default => 0}}
    , {auto_reconnect, fun emqx_connector_schema_lib:auto_reconnect/1}
    ].

-spec to_server_raw(string())
      -> {string(), pos_integer()}.
to_server_raw(Server) ->
    emqx_connector_schema_lib:parse_server(Server, ?REDIS_HOST_OPTIONS).

-spec to_servers_raw(string())
      -> [{string(), pos_integer()}].
to_servers_raw(Servers) ->
    lists:map( fun(Server) ->
                   emqx_connector_schema_lib:parse_server(Server, ?REDIS_HOST_OPTIONS)
               end
             , string:tokens(str(Servers), ", ")).

str(A) when is_atom(A) ->
    atom_to_list(A);
str(B) when is_binary(B) ->
    binary_to_list(B);
str(S) when is_list(S) ->
    S.