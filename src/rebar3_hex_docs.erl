-module(rebar3_hex_docs).

-export([init/1,
         do/1,
         format_error/1]).

-include("rebar3_hex.hrl").

-define(PROVIDER, docs).
-define(DEPS, [{default, edoc}]).

-define(ENDPOINT, "packages").

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
                                {name, ?PROVIDER},
                                {module, ?MODULE},
                                {namespace, hex},
                                {bare, true},
                                {deps, ?DEPS},
                                {example, "rebar3 hex docs"},
                                {short_desc, "Publish documentation for the current project and version"},
                                {desc, ""},
                                {opts, [{revert, undefined, "revert", string, "Revert given version."},
                                        rebar3_hex:repo_opt()]},
                                {profiles, [docs]}]),
    State1 = rebar_state:add_provider(State, Provider),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    case rebar3_hex_config:repo(State) of
        {ok, Repo} ->
            handle_command(State, Repo),
            {ok, State};
        {error, Reason} ->
            ?PRV_ERROR(Reason)
    end.

handle_command(State, Repo) ->
    Apps = rebar3_hex_io:select_apps(rebar_state:project_apps(State)),
    case maps:get(write_key, Repo, undefined) of
        undefined ->
            ?PRV_ERROR(no_write_key);
        _ ->
            lists:foldl(fun(App, {ok, StateAcc}) ->
                                do_(App, StateAcc)
                        end, {ok, State}, Apps),
            {ok, State}
    end.

-spec format_error(any()) -> iolist().
format_error({publish, Status, Package, Version}) when is_integer(Status) ->
    io_lib:format("Error publishing docs for package ~ts ~ts: ~ts",
                  [Package, Version, rebar3_hex_client:pretty_print_status(Status)]);
format_error({publish, Package, Version, Reason}) ->
    io_lib:format("Error publishing docs for package ~ts ~ts: ~p", [Package, Version, Reason]);
format_error({revert, Status, Package, Version}) when is_integer(Status) ->
    io_lib:format("Error deleting docs for package ~ts ~ts: ~ts",
                  [Package, Version, rebar3_hex_client:pretty_print_status(Status)]);
format_error({revert, Package, Version, Reason}) ->
    io_lib:format("Error deleting docs for package ~ts ~ts: ~p", [Package, Version, Reason]);
format_error(Reason) ->
    rebar3_hex_error:format_error(Reason).

do_(App, State) ->
    AppDir = rebar_app_info:dir(App),
    Files = rebar3_hex_file:expand_paths(["doc"], AppDir),
    AppDetails = rebar_app_info:app_details(App),
    Name = binary_to_list(rebar_app_info:name(App)),
    PkgName = rebar_utils:to_list(proplists:get_value(pkg_name, AppDetails, Name)),
    {Args, _} = rebar_state:command_parsed_args(State),
    Revert = proplists:get_value(revert, Args, undefined),

    {ok, Repo} = rebar3_hex_config:repo(State),

    case Revert of
        undefined ->
            Vsn = rebar_app_info:original_vsn(App),

            Tarball = PkgName++"-"++Vsn++"-docs.tar.gz",
            ok = erl_tar:create(Tarball, file_list(Files), [compressed]),
            {ok, Tar} = file:read_file(Tarball),
            file:delete(Tarball),

            case hex_api_publish_docs(Repo, rebar_utils:to_binary(PkgName), rebar_utils:to_binary(Vsn), Tar) of
                {ok, {201, _Headers, _Body}} ->
                    rebar_api:info("Published docs for ~ts ~ts", [PkgName, Vsn]),
                    {ok, State};
                {ok, {Status, _Headers, _Body}} ->
                    ?PRV_ERROR({publish, Status, PkgName, Vsn});
                {error, Reason} ->
                    ?PRV_ERROR({publish, PkgName, Vsn, Reason})
            end;
        Vsn ->
            case hex_api_delete_docs(Repo, rebar_utils:to_binary(PkgName), rebar_utils:to_binary(Vsn)) of
                {ok, {204, _Headers, _Body}} ->
                    rebar_api:info("Successfully deleted docs for ~ts ~ts", [Name, Vsn]),
                    {ok, State};
                {ok, {Status, _Headers, _Body}} ->
                    ?PRV_ERROR({revert, Status, PkgName, Vsn});
                {error, Reason} ->
                    ?PRV_ERROR({revert, PkgName, Vsn, Reason})
            end
    end.

hex_api_publish_docs(Repo, Name, Version, Tarball) ->
    {ok, Config} = rebar3_hex_config:hex_config_write(Repo),

    TarballContentType = "application/octet-stream",

    Headers = maps:get(http_headers, Config, #{}),
    Headers1 = maps:put(<<"content-length">>, integer_to_binary(byte_size(Tarball)), Headers),
    Config2 = maps:put(http_headers, Headers1, Config),

    Body = {TarballContentType, Tarball},
    hex_api:post(Config2, ["packages", Name, "releases", Version, "docs"], Body).

hex_api_delete_docs(Config, Name, Version) ->
    hex_api:delete(Config, ["packages", Name, "releases", Version, "docs"]).

file_list(Files) ->
    [{drop_path(ShortName, ["doc"]), FullName} || {ShortName, FullName} <- Files].

drop_path(File, Path) ->
    filename:join(filename:split(File) -- Path).
