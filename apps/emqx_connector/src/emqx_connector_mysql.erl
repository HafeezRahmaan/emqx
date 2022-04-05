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
-module(emqx_connector_mysql).

-include("emqx_connector.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").

-behaviour(emqx_resource).

%% callbacks of behaviour emqx_resource
-export([ on_start/2
        , on_stop/2
        , on_query/4
        , on_health_check/2
        ]).

-export([connect/1]).

-export([roots/0, fields/1]).

-export([do_health_check/1]).

-define( MYSQL_HOST_OPTIONS
       , #{ host_type => inet_addr
          , default_port => ?MYSQL_DEFAULT_PORT}).

%%=====================================================================
%% Hocon schema
roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    [ {server, fun server/1}
    ] ++
    emqx_connector_schema_lib:relational_db_fields() ++
    emqx_connector_schema_lib:ssl_fields().

server(type) -> emqx_schema:ip_port();
server(required) -> true;
server(validator) -> [?NOT_EMPTY("the value of the field 'server' cannot be empty")];
server(converter) -> fun to_server/1;
server(desc) -> ?SERVER_DESC("MySQL", integer_to_list(?MYSQL_DEFAULT_PORT));
server(_) -> undefined.

%% ===================================================================
on_start(InstId, #{server := {Host, Port},
                   database := DB,
                   username := User,
                   password := Password,
                   auto_reconnect := AutoReconn,
                   pool_size := PoolSize,
                   ssl := SSL } = Config) ->
    ?SLOG(info, #{msg => "starting_mysql_connector",
                  connector => InstId, config => Config}),
    SslOpts = case maps:get(enable, SSL) of
        true ->
            [{ssl, emqx_plugin_libs_ssl:save_files_return_opts(SSL, "connectors", InstId)}];
        false -> []
    end,
    Options = [{host, Host},
               {port, Port},
               {user, User},
               {password, Password},
               {database, DB},
               {auto_reconnect, reconn_interval(AutoReconn)},
               {pool_size, PoolSize}],
    PoolName = emqx_plugin_libs_pool:pool_name(InstId),
    case emqx_plugin_libs_pool:start_pool(PoolName, ?MODULE, Options ++ SslOpts) of
        ok              -> {ok, #{poolname => PoolName}};
        {error, Reason} -> {error, Reason}
    end.

on_stop(InstId, #{poolname := PoolName}) ->
    ?SLOG(info, #{msg => "stopping_mysql_connector",
                  connector => InstId}),
    emqx_plugin_libs_pool:stop_pool(PoolName).

on_query(InstId, {sql, SQL}, AfterQuery, #{poolname := _PoolName} = State) ->
    on_query(InstId, {sql, SQL, [], default_timeout}, AfterQuery, State);
on_query(InstId, {sql, SQL, Params}, AfterQuery, #{poolname := _PoolName} = State) ->
    on_query(InstId, {sql, SQL, Params, default_timeout}, AfterQuery, State);
on_query(InstId, {sql, SQL, Params, Timeout}, AfterQuery, #{poolname := PoolName} = State) ->
    ?TRACE("QUERY", "mysql_connector_received", #{connector => InstId, sql => SQL, state => State}),
    case Result = ecpool:pick_and_do(
                    PoolName,
                    {mysql, query, [SQL, Params, Timeout]},
                    no_handover) of
        {error, Reason} ->
            ?SLOG(error, #{msg => "mysql_connector_do_sql_query_failed",
                connector => InstId, sql => SQL, reason => Reason}),
            emqx_resource:query_failed(AfterQuery);
        _ ->
            emqx_resource:query_success(AfterQuery)
    end,
    Result.

on_health_check(_InstId, #{poolname := PoolName} = State) ->
    emqx_plugin_libs_pool:health_check(PoolName, fun ?MODULE:do_health_check/1, State).

do_health_check(Conn) ->
    ok == element(1, mysql:query(Conn, <<"SELECT count(1) AS T">>)).

%% ===================================================================
reconn_interval(true) -> 15;
reconn_interval(false) -> false.

connect(Options) ->
    mysql:start_link(Options).

-spec to_server(string())
      -> {inet:ip_address() | inet:hostname(), pos_integer()}.
to_server(Str) ->
    emqx_connector_schema_lib:parse_server(Str, ?MYSQL_HOST_OPTIONS).