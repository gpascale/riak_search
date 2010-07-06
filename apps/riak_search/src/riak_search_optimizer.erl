-module(riak_search_optimizer).
-export([
         optimize_or/4
        ]).

-include("riak_search.hrl").
%% -record(config, { default_index, default_field, facets }).

-define(MAX_MULTI_TERM_SZ, 250).
-define(OPTIMIZER_PROC_CT, 32).

terms_to_graph(Terms, Index, Field, Props) ->
    %%
    %% expects:
    %%  [{"function",'dev2@127.0.0.1',1},
    %%
    G = digraph:new(),
    digraph:add_vertex(G, terms, "terms"),
    digraph:add_vertex(G, nodes, "nodes"),
    
    lists:foreach(fun({Term0, Node, _Count}) ->
        Term = {term, {Index, Field, Term0}, Props},
        case digraph:vertex(G, Term) of
            false -> 
                digraph:add_vertex(G, Term, "term"),
                %% terms -> Term
                digraph:add_edge(G, terms, Term, "has-term");
            _ -> skip
        end,
        case digraph:vertex(G, Node) of
            false -> 
                digraph:add_vertex(G, Node, "node"),
                %% nodes -> Node
                digraph:add_edge(G, nodes, Node, "has-member");
            _ -> skip
        end,
        
        %% Term -> Node
        digraph:add_edge(G, Term, Node, "has-location"),
        
        %% Node -> Term
        digraph:add_edge(G, Node, Term, "location-for")
    end, Terms),
    G.

optimize_or(Ops, Index, Field, Props) ->
    G = terms_to_graph(Ops, Index, Field, Props),

    L = lists:map(fun(Node) ->
        {Node, digraph:out_neighbours(G, Node)}
    end, digraph:out_neighbours(G, nodes)),
    
    TCD = lists:sort(fun(A,B) ->
        {_Na, La} = A,
        {_Nb, Lb} = B,
        length(La) >= length(Lb)
    end, L),
    
    Optimized_Ops = 
        lists:foldl(fun(N_NTerms, MultiTermOps) ->
            {Node, NodeTerms} = N_NTerms,
            GOutNeighbors = digraph:out_neighbours(G, terms),
            RemTerms = lists:foldl(fun(RTerm, Acc) ->
                case lists:member(RTerm, GOutNeighbors) of
                        false -> Acc;
                        true -> Acc ++ [RTerm]
                end
            end, [], NodeTerms),
            case RemTerms of
                [] -> MultiTermOps;
                _ ->
                    lists:foreach(fun(Nt) ->
                            digraph:del_edges(G, digraph:edges(G, Nt)),
                            digraph:del_vertex(G, Nt)
                    end, RemTerms),
    
                    L_RemTerms = partition_list(RemTerms, ?MAX_MULTI_TERM_SZ, []),
                    MultiTermOps ++ 
                        lists:map(fun(RemTerms2) ->
                            Vtx = {multi_term, RemTerms2, Node},
                            digraph:add_vertex(G, Vtx),
                            digraph:add_edge(G, terms, Vtx),
                            Vtx 
                        end, L_RemTerms)
            end
        end, [], TCD),
    Optimized_Ops.

partition_list(L, Sz, Acc) ->
    case length(L) =< Sz of
        true -> Acc ++ [L];
        false ->
            {L1, Rest} = lists:split(Sz, L),
            partition_list(Rest, Sz, Acc ++ [L1])
    end.

