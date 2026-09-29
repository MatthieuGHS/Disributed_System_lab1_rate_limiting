------------------------- MODULE RateLimiterLocal -------------------------
(***************************************************************************)
(* WRONG design, for comparison: mode :local of Worker. Each worker has    *)
(* its own counter and decides atomically, but only on ITS traffic.        *)
(* Sticky sessions spread one IP's sessions over several workers, so the   *)
(* real limit becomes |Workers| * L (partial knowledge: "<= L per IP" is   *)
(* an invariant over the state of SEVERAL actors, no single one can        *)
(* enforce it).                                                            *)
(*                                                                         *)
(* RateLimiterLocal.cfg: Safety must be violated (L+1 calls).              *)
(* RateLimiterLocalMax.cfg: TLC must reach |Workers| * L calls, and never  *)
(* more (UpperBound holds).                                                *)
(*                                                                         *)
(* One IP, one window: enough to show the problem.                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Workers, L, MaxReq

VARIABLES
    local,   \* local[w]: counter of worker w
    sent,    \* sent[w]: requests handled by w (bound)
    calls    \* calls received by the API (the oracle)

vars == <<local, sent, calls>>

Init ==
    /\ local = [w \in Workers |-> 0]
    /\ sent = [w \in Workers |-> 0]
    /\ calls = 0

\* Same atomic test-and-increment as the Limiter, on a local counter.
Request(w) ==
    /\ sent[w] < MaxReq
    /\ sent' = [sent EXCEPT ![w] = @ + 1]
    /\ IF local[w] < L
       THEN /\ local' = [local EXCEPT ![w] = @ + 1]
            /\ calls' = calls + 1
       ELSE UNCHANGED <<local, calls>>

Next == \E w \in Workers : Request(w)

Spec == Init /\ [][Next]_vars

Safety == calls <= L

\* What local mode really guarantees.
UpperBound == calls <= Cardinality(Workers) * L

\* Must be VIOLATED: the worst case |Workers| * L is reachable.
MaxNotReached == calls < Cardinality(Workers) * L
=============================================================================
