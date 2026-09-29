---- MODULE Counter ----
EXTENDS Naturals

CONSTANT L

VARIABLE x

Init == x = 0

\* Allowed only while x < L (the guard).
Inc == x < L /\ x' = x + 1

Reset == x' = 0

Next == Inc \/ Reset

Safety == x <= L
====
