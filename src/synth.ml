(* Module for conducting the phi synthesis algorithm 
 * Algorithm comes from Fig. 1 of TACAS'18.
 *)

open Util
open Smt
open Solve
open Spec
open Phi
open Provers
open Choose
open Smt_parsing
open Predicate

type synth_options =
  { preds : pred list option
  ; prover : (module Prover)
  ; lift : bool
  ; timeout : float option
  ; lattice : bool
  }

let default_synth_options =
  { preds = None
  ; prover = (module Provers.ProverCVC4)
  ; lift = true
  ; timeout = None
  ; lattice = false
  }

type benches =
  { predicates : int
  ; predicates_filtered : int
  ; smtqueries : int
  ; mcqueries : int
  ; time : float
  ; synth_time : float
  ; mc_run_time: float
  ; lattice_construct_time: float
  }

let last_benchmarks = ref {predicates = 0; 
                           predicates_filtered = 0; 
                           smtqueries = 0;
                           mcqueries = 0;
                           time = 0.0; 
                           synth_time = 0.0;
                           mc_run_time = 0.0;
                           lattice_construct_time = 0.0}

let string_of_benches benches = sp 
    "predicates, %d\npredicates_filtered, %d\nsmtqueries, %d\nmcqueries, %d\ntime_lattice_construct, %.6f\ntime_mc_run, %.6f\ntime_synth, %.6f\ntime, %.6f" 
    benches.predicates 
    benches.predicates_filtered 
    benches.smtqueries
    benches.mcqueries
    benches.lattice_construct_time
    benches.mc_run_time
    benches.synth_time
    benches.time        

type counterex = exp bindlist

let synth ?(options = default_synth_options) spec m n =
  let init_time = Unix.gettimeofday () in  
  let init_smt_queries = !Provers.n_queries in
  let init_mc_queries = !Model_counter.n_queries in
  let lattice_construct_time = ref 0.0 in

  let spec = if options.lift then lift spec else spec in
  let m_spec = get_method spec m |> mangle_method_vars true in
  let n_spec = get_method spec n |> mangle_method_vars false in

  let preds_unfiltered = match options.preds with
    | None -> generate_predicates spec m_spec n_spec
    | Some x -> x in
  let preds = filter_predicates options.prover spec m_spec n_spec preds_unfiltered in
  
  let construct_lattice ps pps = 
    Choose.order_rels_set := pps;
    let l = L.construct ps in
    pfv "\n\nLATTICE:\n%s" (L.string_of l);
    l
  in
  
  let ps, pps, pequivc, l = if options.lattice then begin
      (* One-time analysis of predicates: 
         1.Get all predicates generated from specs. 
           Append their negated form to the set of candidates
         2.Find all pairs (p1, p2) s.t. p1 => p2
         3.Construct the lattice *)
      let start = Unix.gettimeofday () in
      let ps_, pps_, pequivc_ = Predicate_analyzer.observe_rels spec m_spec n_spec preds in
      Predicate_analyzer_logger.log_predicate_implication_chains ps_ pps_;
      let l_ = construct_lattice ps_ pps_ in
      lattice_construct_time := (Unix.gettimeofday ()) -. start;
      ps_, pps_, pequivc_, l_ end 
    else
      (* make trivial lattice *)
      [], [], [], construct_lattice (List.map (fun p -> P p) preds) []
  in

  let pfind p pequivc l =
      let ps' = List.find (fun ps -> List.mem p ps) pequivc in
      match List.fold_right (fun p res ->
          match res with
          | Some _ -> res
          | None -> L.find_opt ((=) p) l 
        ) ps' None with
      | Some pr -> pr
      | None -> raise @@ Failure (sp "Predicate %s not found" (string_of_predP p))
  in

  let synth_start_time = Unix.gettimeofday () in

  seq (last_benchmarks :=
     { predicates = List.length preds_unfiltered
     ; predicates_filtered = List.length preds
     ; smtqueries = !Provers.n_queries - init_smt_queries
     ; mcqueries = !Model_counter.n_queries - init_mc_queries
     ; time = Float.sub (Unix.gettimeofday ()) init_time 
     ; synth_time = (Unix.gettimeofday ()) -. synth_start_time -. !Choose.mc_run_time
     ; mc_run_time = !Choose.mc_run_time
     ; lattice_construct_time = !lattice_construct_time }) @@

  let answer_incomplete = ref false in
  let phi = ref @@ Disj [] in
  let phi_tilde = ref @@ Disj [] in

  let solve_inst = solve options.prover spec m_spec n_spec in

  let env = {
    solver = solve_inst;
    spec = spec;
    m_spec = m_spec;
    n_spec = n_spec;
    h = Conj [];
    choose_from = l;
    cex_ncex = ([], [])
  }
  in

  let simplify_preh preh p = 
    let preh = List.flatten @@ List.map (fun mp -> 
        match predP_of_atom mp with Some p_ -> [p_] | None -> []) (un_conj preh) 
    in
    Conj (List.map atom_of_predP @@ List.filter (fun p' -> not @@ PO.lte p p') preh)
  in
                                              
  (* preh is the h of the last iteration, maybep is Some predicate that was added last iteration. *)
  let rec refine_wrapped preh maybep l = 
    try refine preh maybep l with Failure _ -> answer_incomplete := true
  and refine: conjunction -> predP option -> predP L.el L.t -> unit = 
    fun preh maybep l -> 
    let p_set = L.list_of l in
    let pred_smt = List.map exp_of_predP p_set in
    let h = match maybep with
      | None -> preh
      | Some p -> add_conjunct (exp_of_predP p) preh (* (simplify_preh preh p) *)
    in
    
    begin match solve_inst pred_smt @@ commute spec h with
      | Unsat ->         
        pfv "\nPred found for phi: %s\n" 
          (string_of_smt @@ smt_of_conj h);
        phi := add_disjunct h !phi
      | Unknown -> raise @@ Failure "commute failure"
      | Sat vs -> 
        let com_cex = pred_data_of_values vs in
        begin match solve_inst pred_smt @@ non_commute spec h with
          | Unsat ->
            pfv "\nPred found for phi-tilde: %s\n" 
              (string_of_smt @@ smt_of_conj h);
            phi_tilde := add_disjunct h !phi_tilde
          | Unknown -> raise @@ Failure "non_commute failure"
          | Sat vs -> 
            let non_com_cex = pred_data_of_values vs in
            let p = !choose { env with h = h; choose_from = l; cex_ncex = (com_cex, non_com_cex) }
            in
            (* current p is not concluding, then 
               - add it to preh, and 
               - remove all its upper set (which comprises weaker predicates)      
            *)
            let preh, l = begin match maybep with
              | None -> preh, l
              | Some p ->
                pfv "\nUpperset removed: [%s]\n" 
                  (String.concat " ; " 
                     (List.map (fun p -> string_of_predP p) (L.upperset_of_v p l))); 
                (add_conjunct (exp_of_predP p) preh), L.remove_upperset p l 
            end in
            (* find the equivalent of non p *)
            let p_lattice = if options.lattice then pfind p pequivc l else p in
            let nonp_lattice = if options.lattice then pfind (negate p) pequivc l else (negate p) in
            let l = L.remove p_lattice l |> L.remove nonp_lattice in
            refine_wrapped preh (Some p_lattice) l;
            refine_wrapped preh (Some nonp_lattice) l
        end 
    end
  in

  begin try (
    match options.timeout with 
    | None -> run 
    | Some f -> run_with_time_limit f
  ) (fun () -> 
      refine_wrapped (Conj []) None l
    ) 
    with Timeout -> 
      pfv "Time limit of %.6fs exceeded.\n" (Option.get options.timeout); 
      answer_incomplete := true
  end;

  if !answer_incomplete then pfv "Warning: Answer incomplete.\n";
  !phi, !phi_tilde
