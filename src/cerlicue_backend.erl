-module(cerlicue_backend).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-record(s, {nicks=dict:new(),
            channels=dict:new(),
            pids=dict:new()}).

-record(ch, {clients=[], topic, mode}).

-record(cl, {pid, mode, realname}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
         nick/2,
         user/4,
         privmsg/3,
         join/2,
         part/3,
         mode/1,
         topic/1,
         topic/2,
         names/1,
         whois/1
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% ok
% {error, 432} (erroneous nickname)
% {error, 433} (nickname already in use)
nick(Nick, Pid) ->
    gen_server:call(?SERVER, {nick, Nick, Pid}).

% ok
% {error, 462} (already registered)
user(Nick, Mode, Realname, Pid) ->
    gen_server:call(?SERVER, {user, Nick, Mode, Realname, Pid}).

% ok
% {error, 401} (no such nick)
% {error, 403} (no such channel)
privmsg(Nick, Msg, Client) ->
    gen_server:call(?SERVER, {privmsg, Nick, Msg, Client}).

% ok
% {error, 403} (no such channel, i.e. invalid channel name)
join(Channel, Client) ->
    gen_server:call(?SERVER, {join, Channel, Client}).

% {ok, Topic, Setter, AtTime}
% {error, 331} (no topic set)
% {error, 403} (no such channel)
topic(Channel) ->
    gen_server:call(?SERVER, {topic, Channel}).

% ok
% {error, 403} (no such channel)
% {error, 442} (not on that channel)
% {error, 482} (not a channel operator)
topic(Channel, NewTopic) ->
    gen_server:call(?SERVER, {topic, Channel, NewTopic}).

mode(Channel) ->
    gen_server:call(?SERVER, {mode, Channel}).

names(Channel) ->
    gen_server:call(?SERVER, {names, Channel}).

part(Channel, Msg, Client) ->
    gen_server:call(?SERVER, {part, Channel, Msg, Client}).

whois(Nick) ->
    gen_server:call(?SERVER, {whois, Nick}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    {ok, #s{}}.

% ok
% {error, 433}
handle_call({nick, Nick, Pid},
            _From,
            State=#s{nicks=Nicks, pids=Pids, channels=Channels}) ->
    case dict:find(Nick, Nicks) of
        {ok, _OtherPid} ->
            {reply, errno(433), State};
        error ->
            case dict:find(Pid, Pids) of
                {ok, OldNick} ->
                    lists:foreach(fun(Buddy) ->
                                          Buddy ! {nick, OldNick, Nick}
                                  end,
                                  buddies(Pid, Channels)),
                    NewNicks = dict:store(Nick, Pid, dict:erase(OldNick, Nicks));
                error ->
                    NewNicks = dict:store(Nick, Pid, Nicks),
                    erlang:monitor(process, Pid)
            end,
            NewPids = dict:store(Pid, Nick, Pids),
            {reply, ok, State#s{nicks=NewNicks, pids=NewPids}}
    end;

% ok
% {error, 403} (no such channel)
handle_call({privmsg, Channel="#"++_, Msg, Sender},
            _From,
            State=#s{channels=Channels, pids=Pids}) ->
    {ok, SenderNick} = dict:find(Sender, Pids),
    case dict:find(Channel, Channels) of
        {ok, Clients} ->
            Recipients = lists:delete(Sender, Clients),
            lists:foreach(fun(Recipient) ->
                                  Recipient ! {privmsg, SenderNick, Channel, Msg}
                          end,
                          Recipients),
            {reply, ok, State};
        error ->
            {reply, errno(403), State}
    end;

% ok
% {error, 401} (no such nick)
handle_call({privmsg, Nick, Msg, Sender},
            _From,
            State=#s{nicks=Nicks, pids=Pids}) ->
    {ok, SenderNick} = dict:find(Sender, Pids),
    case dict:find(Nick, Nicks) of
        {ok, Pid} ->
            Pid ! {privmsg, SenderNick, Nick, Msg},
            {reply, ok, State};
        error ->
            {reply, errno(401), State}
    end;

% ok
handle_call({join, Channel, Client},
            _From,
            State=#s{channels=Channels, pids=Pids}) ->
    {ok, SenderNick} = dict:find(Client, Pids),
    Clients = case dict:find(Channel, Channels) of
        {ok, Cs} ->
            Cs;
        error ->
            []
    end,
    lists:foreach(fun(C) ->
                          C ! {join, SenderNick, Channel}
                  end,
                  Clients),
    NewChannels = dict:store(Channel, [Client|Clients], Channels),
    Nicks = [SenderNick|[dict:fetch(C, Pids) || C <- Clients]],
    {reply, {ok, Nicks}, State#s{channels=NewChannels}};

% {ok, Topic}
% {error, 403} (no such channel)
handle_call({topic, Channel}, _From, State=#s{channels=Channels}) ->
    case dict:find(Channel, Channels) of
        {ok, _Clients} ->
            {reply, {ok, "fun topic"}, State};
        error ->
            {reply, errno(403), State}
    end;

% {ok, Mode}
% {error, 403} (no such channel)
handle_call({mode, Channel}, _From, State=#s{channels=Channels}) ->
    case dict:find(Channel, Channels) of
        {ok, _Clients} ->
            {reply, {ok, "+ns"}, State};
        error ->
            {reply, errno(403), State}
    end;

% {ok, Nicks}
% {error, 403} (no such channel)
handle_call({names, Channel}, _From, State=#s{channels=Channels, pids=Pids}) ->
    case dict:find(Channel, Channels) of
        {ok, Clients} ->
            Names = [dict:fetch(C, Pids) || C <- Clients],
            {reply, {ok, Names}, State};
        error ->
            {reply, errno(403), State}
    end;

% ok
% {error, 403} (no such channel)
% {error, 442} (not on that channel)
handle_call({part, Channel, Msg, Client},
            _From,
            State=#s{channels=Channels, pids=Pids}) ->
    {ok, SenderNick} = dict:find(Client, Pids),
    case dict:find(Channel, Channels) of
        {ok, Clients} ->
            case lists:member(Client, Clients) of
                true ->
                    OtherClients = lists:delete(Client, Clients),
                    lists:foreach(fun(Recipient) ->
                                          Recipient ! {part, SenderNick, Channel, Msg}
                                  end,
                                  OtherClients),
                    NewChannels = dict:store(Channel, OtherClients, Channels),
                    {reply, ok, State#s{channels=NewChannels}};
                false ->
                    {reply, errno(442), State}
            end;
        error ->
            {reply, errno(403), State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason},
            State=#s{nicks=Nicks, pids=Pids, channels=Channels}) ->
    {ok, Nick} = dict:find(Pid, Pids),
    lists:foreach(fun(Buddy) ->
                          Buddy ! {quit, Nick, ""}
                  end,
                  buddies(Pid, Channels)),
    NewNicks = dict:erase(Nick, Nicks),
    NewPids = dict:erase(Pid, Pids),
    NewChannels = remove_client(Pid, Channels),
    {noreply, State#s{nicks=NewNicks, channels=NewChannels, pids=NewPids}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

buddies(Pid, Channels) ->
    Set = dict:fold(fun(_ChannelName, Clients, Buddies) ->
                            case lists:member(Pid, Clients) of
                                true ->
                                    ClientSet = sets:from_list(Clients),
                                    sets:union(Buddies, ClientSet);
                                false ->
                                    Buddies
                            end
                    end,
                    sets:new(),
                    Channels),
    sets:to_list(Set).

remove_client(Client, Channels) ->
    dict:fold(fun(ChannelName, Clients, Acc) ->
                      NewClients = lists:delete(Client, Clients),
                      dict:store(ChannelName, NewClients, Acc)
              end,
              dict:new(),
              Channels).

errno(Num) ->
    {error, Num}.