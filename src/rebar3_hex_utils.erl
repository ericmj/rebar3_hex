-module(rebar3_hex_utils).

-export([pretty_print_status/1,
         pretty_print_errors/1,
         repo_opt/0,
         repo/1,
         format_error/1,
         update_app_src/2,
         select_apps/1,
         binarify/1,
         expand_paths/2,
         get_password/1]).

-include("rebar3_hex.hrl").

pretty_print_status(401) -> "Authentication failed (401)";
pretty_print_status(403) -> "Forbidden (403)";
pretty_print_status(404) -> "Entity not found (404)";
pretty_print_status(422) -> "Validation failed (422)";
pretty_print_status(Code) -> io_lib:format("HTTP status code: ~p", [Code]).

pretty_print_errors(Errors) ->
  L =  maps:fold(fun(K,V,Acc) ->
                Acc ++ [<<K/binary, " ", V/binary>>]
        end,
    [],
  Errors),
  binary:list_to_bin(lists:join(", ", L)).

repo_opt() ->
    {repo, $r, "repo", string, "Repository to use for this command."}.

repo(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    Resources = rebar_state:resources(State),
    #{repos := Repos} = rebar_resource_v2:find_resource_state(pkg, Resources),
    case proplists:get_value(repo, Args, undefined) of
        undefined ->
            [Repo | _] = Repos,
            Repo;
        RepoName ->
            case rebar_hex_repos:get_repo_config(rebar_utils:to_binary(RepoName), Repos) of
                {ok, Repo} ->
                    Repo;
                _ ->
                    throw(?PRV_ERROR({not_valid_repo, RepoName}))
            end
    end.

format_error({not_valid_repo, RepoName}) ->
    io_lib:format("No configuration for repository ~ts found.", [RepoName]).

-define(OP_PUTC, 0).

get_password(Msg) ->
    case os:type() of
        {win32, nt} ->
            get_win32_password(Msg);
         _ ->
            get_passwd(Msg)
    end.

get_passwd(Msg) ->
    case io:setopts([binary, {echo, false}]) of
        ok ->
            PwLine = io:get_line(Msg),
            ok = io:setopts([binary, {echo, true}]),
            io:format("\n"),
            [Pw | _] = binary:split(PwLine, <<"\n">>),
            Pw;
        _ ->
            error_logger:tty(false),
            Port = open_port({spawn, "tty_sl -e"}, [binary, eof]),
            port_command(Port, <<?OP_PUTC, Msg/binary>>),
            receive
                {Port, {data, PwLine}} ->
                    [Pw | _] = binary:split(PwLine, <<"\n">>),
                    port_command(Port, <<?OP_PUTC, $\n>>),
                    port_close(Port),
                    error_logger:tty(true),
                    Pw
            end
    end.

get_win32_password(Msg) ->
    F = fun() -> win32_password_loop(Msg) end,
    Pid = spawn_link(F),
    Ref = make_ref(),
    Val = io:get_line(Msg),
    Pid ! {done, self(), Ref},
    receive
        {done, Pid, Ref}
        -> ok
    end,
    list_to_binary(string:chomp(Val)).

win32_password_loop(Prompt) ->
    receive
        {done, Parent, Ref} ->
            Parent  ! {done, self(), Ref},
            io:fwrite(standard_error, "\e[2K\r", [])
    after
        1 ->
            io:fwrite(standard_error, "\e[2K\r~ts", [Prompt]),
            win32_password_loop(Prompt)
    end.

update_app_src(App, Version) ->
    AppSrcFile = rebar_app_info:app_file_src(App),
    AppSrc = rebar_file_utils:try_consult(AppSrcFile),
    [{application, Name, Details}] = AppSrc,

    NewDetails = lists:keyreplace(vsn, 1, Details, {vsn, ec_cnv:to_list(Version)}),

    {application, Name, NewDetails}.

select_apps([App]) ->
    [App];
select_apps(Apps) ->
    ec_talk:say("Select application(s):", []),
    lists:foldl(fun(App, Idx) ->
                        ec_talk:say("~p) ~s", [Idx, rebar_app_info:name(App)]),
                        Idx+1
                end, 1, Apps),
    ec_talk:say("------------", []),
    ec_talk:say("A) All", []),
    case ec_talk:ask_default(io_lib:format("[1-~p] or (A)ll ", [length(Apps)]), string, "A") of
        "A" ->
            Apps;
        Index ->
            [lists:nth(list_to_integer(Index), Apps)]
    end.

binarify(Term) when is_boolean(Term) ->
    Term;
binarify(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);
binarify([]) ->
    [];
binarify(Map) when is_map(Map) ->
    maps:from_list(binarify(maps:to_list(Map)));
binarify(Term) when is_list(Term) ->
    case io_lib:printable_unicode_list(Term) of
        true ->
            unicode:characters_to_binary(Term);
        false ->
            [binarify(X) || X <- Term]
    end;
binarify({Key, Value}) ->
    {binarify(Key), binarify(Value)};
binarify(Term) ->
    Term.

expand_paths(Paths, Dir) ->
    AbsDir = filename:absname(Dir),
    Files = lists:flatmap(fun dir_files1/1, [filename:join(Dir, P) || P <- Paths]),
    [{F1 -- (AbsDir++"/"), F1} || F1 <- filter_regular(Files)].

dir_files1(Dir) ->
    lists:flatmap(fun(Y) -> dir_files(Y) end, filelib:wildcard(Dir)).

filter_regular(Files) ->
    lists:filter(fun filelib:is_regular/1, [filename:absname(F) || F <- Files]).

dir_files(Path) ->
    case filelib:is_dir(Path) of
        true ->
             filelib:wildcard(filename:join(Path, "**"));
        false ->
            [Path]
    end.
