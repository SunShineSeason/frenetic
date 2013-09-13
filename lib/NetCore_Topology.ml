open NetCore_Util
open NetCore_Types
open Graph


module type NODE =
sig
  type t = Host of string
           | Switch of string * switchId
           | Mbox of string * string list

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_dot : t -> string
  val to_string : t -> string

  val id_of_switch : t -> switchId
end

module type LINK =
sig
  type v
  type t = {
    srcport : portId;
    dstport : portId;
    cost : int64;
    capacity : int64;
  }
  type e = (v * t * v)
  val default : t
  val compare : t -> t -> int

  (* Constructors *)
  val mk_edge : v -> v -> t -> e
  val mk_link : v -> int -> v -> int -> int64 -> int64 -> e
  val reverse : e -> e

  (* Accesssors *)
  val src : e -> v
  val dst : e -> v
  val label : e -> t

  val capacity : e -> Int64.t
  val cost : e -> Int64.t
  val srcport : e -> Int32.t
  val dstport : e -> Int32.t

  (* Utilities *)
  val name : e -> string
  val string_of_label : e -> string
  val to_dot : e -> string
  val to_string : e -> string
end

module type TOPO =
sig
  include Sig.P

  (* Constructors *)
  val add_node : t -> V.t -> t
  val add_host : t -> string -> t
  val add_switch : t -> string -> switchId -> t
  val add_switch_edge : t -> V.t -> portId -> V.t -> portId -> t

  (* Accessors *)
  val get_vertices : t -> V.t list
  val get_edges : t -> E.t list
  val get_ports : t -> V.t -> V.t -> (portId * portId)
  val get_hosts : t -> V.t list
  val get_switches : t -> V.t list
  val get_switchids : t -> switchId list
  val ports_of_switch : t -> V.t -> portId list
  val edge_ports_of_switch : t -> V.t -> portId list
  val next_hop : t -> V.t -> portId -> V.t

  (* Utility functions *)
  val shortest_path : t -> V.t -> V.t -> E.t list
  val to_dot : t -> string
  val to_string : t -> string
  val to_mininet : t -> string

  (* Exceptions *)
  exception NotFound of string
  exception NoPath of string * string
end

(***** Concrete types for network topology *****)
module Node =
struct
  type t = Host of string
           | Switch of string * switchId
           | Mbox of string * string list
  let equal = Pervasives.(=)
  let hash = Hashtbl.hash
  let compare = Pervasives.compare
  let to_dot n = match n with
    | Host(s) -> s
    | Switch(s,i) -> s
    | Mbox(s,_) -> s
  let to_string = to_dot
  let id_of_switch n =
    match n with
      | Switch(_,i) -> i
      | _ -> failwith "Not a switch"
end

module Link =
struct
  type v = Node.t
  type t = {
    srcport : portId;
    dstport : portId;
    cost : int64;
    capacity : int64;
  }
  type e = v * t * v
  let compare = Pervasives.compare
  let default = {
    srcport = Int32.zero;
    dstport = Int32.zero;
    cost = Int64.zero;
    capacity = Int64.max_int
  }

  (* Constructors and mutators *)
  let mk_edge s d l = (s,l,d)

  let mk_link s sp d dp cap cost =
    ( s,
     {srcport = Int32.of_int sp; dstport = Int32.of_int dp;
      cost = cost; capacity = cap;},
    d)

  let reverse (s,d,l) =
    ( d, s,
      { srcport = l.dstport; dstport = l.srcport;
        cost = l.cost; capacity = l.capacity }
    )

  (* Accessors *)
  let src (s,l,d) = s
  let dst (s,l,d) = d
  let label (s,l,d) = l

  let capacity (s,l,d) = l.capacity
  let cost (s,l,d) = l.cost
  let srcport (s,l,d) = l.srcport
  let dstport (s,l,d) = l.dstport

  let reverse (s,l,d) =
    ( d,
      { srcport = l.dstport; dstport = l.srcport;
        cost = l.cost; capacity = l.capacity },
      s
    )

  let name (s,_,d) =
    Printf.sprintf "%s_%s" (Node.to_string s) (Node.to_string d)
  let string_of_label (s,l,d) =
    Printf.sprintf "{srcport = %ld; dstport = %ld; cost = %Ld; capacity = %Ld;}"
      l.srcport l.dstport l.cost l.capacity
  let to_dot (s,l,d) =
    let s = Node.to_dot s in
    let d = Node.to_dot d in
    Printf.sprintf "%s -> %s [label=\"%s\"]" s d (string_of_label (s,l,d))
  let to_string = to_dot
end

module EdgeOrd = struct
  type t = Node.t * Link.t * Node.t
  let src (s,_,_) = s
  let dst (_,_,d) = d
  let label (_,l,_) = l
  let compare = Pervasives.compare
end

module EdgeSet = Setplus.Make(EdgeOrd)

module EdgeMap = Mapplus.Make(EdgeOrd)

module Topology =
struct
  module G = Persistent.Digraph.ConcreteBidirectionalLabeled(Node)(Link)
  include G
  module Dij = Path.Dijkstra(G)(struct
      type t = int
      type label = Link.t
      let weight _ = 1
      let compare = Pervasives.compare
      let add = Pervasives.(+)
      let zero = 0
  end)
  (* Functions to mimic NetCore's graph interface circa frenetic-lang/frenetic:master
     commit 52f490eb24fd42f427a46fb814cc9bc9341d1318 *)

  exception NotFound of string
  exception NoPath of string * string

  (* Alias for add_vertex *)
  let add_node (g:t) (n:Node.t) : t =
    add_vertex g n

  (* Add a host, given its name, to the graph *)
  let add_host (g:t) (h:string) : t =
    add_vertex g (Node.Host h)


  (* Add a switch (from it's name and id) to the graph *)
  let add_switch (g:t) (s:string) (i:switchId) : t =
    add_vertex g (Node.Switch(s,i))


  (* Add an edge between particular ports on two switches *)
  let add_switch_edge (g:t) (s:Node.t) (sp:portId) (d:Node.t) (dp:portId) : t =
    let l = {Link.default with Link.srcport = sp; Link.dstport = dp} in
    add_edge_e g (s,l,d)


  (****** Accessors ******)
  (* Get a list of all the vertices in the graph *)
  let get_vertices (g:t) : (V.t list) =
    fold_vertex (fun v acc -> v::acc) g []


  (* Get a list of all the edges in the graph. *)
  let get_edges (g:t) : (E.t list) =
    fold_edges_e (fun e acc -> e::acc) g []


  (* For a given pair of nodes in the graph, return the list of port pairs that
     connect them.
     Raise NotFound if there are the two nodes are not connected *)
  let get_ports (g:t) (s:Node.t) (d:Node.t) : (portId * portId) =
    let es = find_all_edges g s d in
    if List.length es = 0
    then raise (NotFound (Printf.sprintf "Can't find %s to get_ports to %s\n"
                            (Node.to_string s) (Node.to_string d)))
    else let e = List.hd es in
         (Link.srcport e, Link.dstport e)


  (* Get a list of the hosts out in the graph. Returns an empty list if
     there are no hosts.  *)
  let get_hosts (g:t) : (Node.t list) =
    fold_vertex (fun v acc -> match v with
      | Node.Host(_) -> v::acc
      | _ -> acc
    ) g []


  (* Get a list of the switches out in the graph. Returns an empty list if
     there are no switches.  *)
  let get_switches (g:t) : (Node.t list) =
    fold_vertex (fun v acc -> match v with
      | Node.Switch(_,_) -> v::acc
      | _ -> acc
    ) g []


  (* Get a list of the switch IDs in the graph. Returns an empty list if
     there are no switches.  *)
  let get_switchids (g:t) : (switchId list) =
    fold_vertex (
      fun v acc -> match v with
        | Node.Switch(_,i) -> i::acc
        | _ -> acc
    ) g []


  (* For a given node, return all its connected ports.
     Raise NotFound if the node is not in the graph *)
  let ports_of_switch (g:t) (s:Node.t) : portId list =
    let ss = try (succ_e g s)
      with Not_found -> raise (NotFound(Printf.sprintf
                                          "Can't find %s to get ports_of_switch\n"
                                          (Node.to_string s))) in
    let sports = List.map
      (fun l -> Link.srcport l) ss in
    let ps = pred_e g s in
    let pports = List.map
      (fun l -> Link.srcport l) ps in
    sports @ pports


  (* For a given switch, return the ports that are connected to hosts.
     Raise NotFound if either the node is not in the graph. *)
  let edge_ports_of_switch (g:t) (s:Node.t) : portId list =
    let ss = try (succ_e g s)
      with Not_found -> raise (NotFound(Printf.sprintf
                                          "Can't find %s to get ports_of_switch\n"
                                          (Node.to_string s))) in
    let sports = List.fold_left
      (fun acc l -> match (Link.dst l) with
        | Node.Host(_) -> Int32Set.add (Link.srcport l) acc
        | _ -> acc
      ) Int32Set.empty ss in
    let ps = pred_e g s in
    let pports = List.fold_left
      (fun acc l -> match (Link.src l) with
        | Node.Host(_) -> Int32Set.add (Link.dstport l) acc
        | _ -> acc
      ) sports ps in
    Int32Set.elements pports


  (* Get the next hop node for a given node and port. Raise NotFound if either
  the given node is not in the graph, or if the given port is not connected to
  another node.  *)
  let next_hop (g:t) (n:Node.t) (p:portId) : Node.t =
    let ss = try (succ_e g n)
      with Not_found -> raise (NotFound(Printf.sprintf
                                          "Can't find %s to get next_hop\n"
                                          (Node.to_string n))) in
    let (_,_,d) = try (List.hd
                         (List.filter (fun e -> Link.srcport e = p) ss))
      with Failure hd -> raise (NotFound(Printf.sprintf
                                           "next_hop: Port %ld is not connected\n" p))
    in d


  (* Find the shortest path between two nodes using Dijkstra's algorithm,
     returning the list of edges making up the path. The implementation is from
     the ocamlgraph library.
     Raise NoPath if there is no such path. *)

  let shortest_path (g:t) (src:Node.t) (dst:Node.t) : E.t list = 
	let ret,_ = Dij.shortest_path g src dst in ret

(*  let shortest_path (g:t) (src:Node.t) (dst:Node.t) : E.t list =
    let p,_ = Dij.shortest_path g src dst in
    if p = [] then raise (NoPath(Node.to_string src, Node.to_string dst))
    else p *)


  (* Produce a dot representation of the topology, usable by Graphviz *)
  let to_dot g =
    let edges = get_edges g in
    let es = list_intercalate Link.to_dot "\n" edges in
    Printf.sprintf "digraph G {\n%s\n}" es

  let to_string = to_dot


  (* Produce a Mininet script that implements the given topology *)
  let to_mininet (g:t) : string =
    (* Load static strings (maybe there's a better way to do this?) *)
    let prologue = load_file "examples/mn_prologue.txt" in
    let epilogue = load_file "examples/mn_epilogue.txt" in

    (* Check if an edge or its reverse has been added already *)
    let seen = ref EdgeSet.empty in
    let not_printable e =
      E.src e = E.dst e ||
      EdgeSet.mem e !seen ||
      EdgeSet.mem (Link.reverse e) !seen
    in

    (* Add the hosts and switches *)
    let add_hosts = fold_vertex
      (fun v acc ->
        let add = match v with
          | Node.Host(n) -> Printf.sprintf "    %s = net.addHost(\'%s\')\n" n n
          | Node.Switch(s,_) -> Printf.sprintf
            "    %s = net.addSwitch(\'%s\')\n" s s
          | Node.Mbox(s,_) -> Printf.sprintf
            "    %s = net.addSwitch(\'%s\')\n" s s in
        acc ^ add
      )
      g "" in

    (* Add links between them *)
    let links = fold_edges_e
      (fun e acc ->
        let add =
          if (not_printable e) then ""  (* Mininet links are bidirectional *)
          else
            Printf.sprintf "    net.addLink(%s, %s, %ld, %ld)\n"
              (Node.to_string (E.src e)) (Node.to_string (E.dst e))
              (Link.srcport e) (Link.dstport e)
        in
        seen := EdgeSet.add e !seen;
        acc ^ add
      )
      g "" in
    prologue ^ add_hosts ^ links ^ epilogue

end