open Smt
open Util
open Solve
open Provers
open Phi

(* Assume that all predicate lists are sorted by complexity *)

let differentiating_predicates (ps : pred list) (a : bool list) b : ((pred * bool) list) = (* The bool should be true if the predicate is true in the commute (first list) case *)
    (* TODO: Account for a/b not being simple true/false *)
    List.fold_right2 (fun p (x, y) acc -> if (x != y) then (p, y) :: acc else acc) ps (List.map2 (fun x y -> (x, y)) a b) []

let rec size = function
  | EVar _ -> 1
  | EArg _ -> raise @@ UnreachableFailure "Unbaked indexed argument"
  | EConst _ -> 1
  | EBop(_, e1, e2) -> 1 + size e1 + size e2
  | EUop(_, e) -> 1 + size e
  | ELop(_, es) -> 1 + list_sum (List.map size es)
  | ELet(_, e) -> 1 + size e
  | EITE(e1, e2, e3) -> 1 + size e1 + size e2 + size e3
  | EFunc(_, es) -> 1 + list_sum (List.map size es)

let complexity : pred -> int = memoize @@ fun (_, left, right) -> size left + size right

let simple _ h ps com n_com : pred =
    differentiating_predicates ps com n_com |> List.hd |> fst

let poke solver h ps com n_com : pred =
    let next = differentiating_predicates ps com n_com in
    let diff_preds = List.map fst next in (* TODO: if ps is large, avoid multiple maps *)
    let smt_diff_preds = List.map smt_of_pred diff_preds in
    let weight_fn p cov =
        let h'  = add_conjunct ((if cov then id else not_atom) @@ atom_of_pred p) h in
        let h'' = add_conjunct ((if cov then not_atom else id) @@ atom_of_pred p) h in
        match solver smt_diff_preds @@ commute h' with (* TODO: Possibly cache these results as synth also uses them? *)
        | Unsat -> -1
        | Unknown -> max_int (* TODO: Better way to encode this? *)
        | Sat s -> begin let com_cex = parse_pred_data s in
            match solver smt_diff_preds @@ non_commute h'' with
            | Unsat -> -1
            | Unknown -> max_int
            | Sat s -> begin let non_com_cex = parse_pred_data s in
                let l = (differentiating_predicates diff_preds com_cex non_com_cex) in print_string (ToMLString.list (compose string_of_pred fst) l); List.length l
                end
            end in
    fst4 @@ match next with 
        | [] -> failwith "poke"
        | (p, b) :: next' -> List.fold_left (fun (p, cov, weight, shortcircuit) (e, e_cov) ->
        if shortcircuit then (p, cov, weight, shortcircuit) else
        let e_weight = weight_fn e e_cov  in 
        if e_weight = -1 then (e, e_cov, e_weight, true) else
        if e_weight < weight then (e, e_cov, e_weight, false) else
        (p, cov, weight, false)) (let weight = weight_fn p b in (p, b, weight, weight = -1)) next'

let choose : ((exp list -> exp -> solve_result) -> conjunction -> pred list -> bool list -> bool list -> pred) ref = ref simple
