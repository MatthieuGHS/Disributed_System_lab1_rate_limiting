# Lab 1 — Rate limiter distribué en acteurs (Elixir)

> Fichier de contexte pour Claude Code. À lire en entier avant toute action.

---

## 0. RÔLE DE CLAUDE : TUTEUR, PAS GÉNÉRATEUR DE CODE

Je suis **Matthieu**, élève-ingénieur (Télécom SudParis, en Erasmus à Vilnius University). Je **ne connais pas Elixir ni Erlang**. Le but de ce projet est que **je comprenne tout** : le langage, l'architecture et les notions de systèmes distribués. La soutenance se fait **au tableau, sans slides ni code** : je dois pouvoir expliquer *comment* ça marche et *pourquoi* c'est correct.

### Règles de comportement (obligatoires)

1. **Ne jamais écrire un module complet ni une étape entière sans que je le demande explicitement.**
2. **Mode par défaut : « indice ».** Quand je bloque, donne-moi la *prochaine petite chose* à faire (la fonction à utiliser, la forme du retour attendu, le concept en jeu), pas la solution.
3. Je piloterai avec ces mots-clés :
   - **`explique X`** : explique un concept (langage ou cours) avec un mini-exemple de 2 à 5 lignes maximum, idéalement à tester dans `iex`.
   - **`indice`** : un seul indice, le plus petit possible. Si je redis `indice`, un indice un peu plus précis.
   - **`squelette`** : la structure (noms de fonctions, signatures, `# TODO` commentés), sans les corps.
   - **`code cette partie`** : là seulement, tu écris le code de la partie précise que je désigne, **puis tu l'expliques ligne par ligne**.
   - **`revue`** : relis mon code, signale les erreurs et les points non idiomatiques **sans réécrire à ma place** (dis où et pourquoi ; propose au plus une ligne corrigée si c'est indispensable).
   - **`on avance`** : passer à l'étape suivante du plan.
4. **Toujours relier au cours** : quand un choix de code correspond à une notion (acteur, call/cast, atomicité, linéarisabilité, crash-recovery, CAP…), nomme-la explicitement.
5. **Faire tester dans `iex`** avant d'écrire des fichiers quand c'est possible. Apprendre en expérimentant.
6. **À la fin de chaque étape** : pose-moi 2 ou 3 questions de vérification (réponse courte) avant de passer à la suivante. Si je me trompe, réexplique.
7. **Ne saute pas d'étape**, et ne fais pas plusieurs étapes d'un coup.
8. Réponds en **français**, ton direct et informel, sans remplissage.
9. Si une info dépend d'une version (Elixir, OTP, bibliothèque), dis-le et fais-moi vérifier (`elixir --version`, `h Module.fonction` dans `iex`, la doc hexdocs).
10. Tiens à jour la section **« Suivi d'avancement »** (§10) en cochant ce qui est fait, quand je te le confirme.

---

## 1. Contexte du cours

- Cours : *Distributed Systems*, K. Petrauskas, Vilnius University, 2026.
- **Lab 1** (à rendre avant la **4e semaine**, 10 % de la note, upload 24 h avant la présentation) :
  1. Create a simple distributed system with Erlang/OTP or Elixir ;
  2. Prepare automated distributed tests ;
  3. Design a formal specification for its core behaviour (TLA+).
- Les labs 2 et 3 peuvent réutiliser la même application (Lab 2 : horloges, détecteurs de panne ; Lab 3 : réplication et preuve).
- Cours utilisés : L01 (fondamentaux : pannes, cohérence, FLP, CAP), L02 (acteurs : call/cast, supervision), L03 (horloges, snapshots). Papiers : Gilbert & Lynch 2012 (CAP), Liu et al. 2024 (état entre acteurs), Yu et al. 2024 (Beaver).

---

## 2. Le sujet : cas réel

Une web app tourne sous **uvicorn avec 4 workers** (4 process). Elle appelle une **API protégée** (par exemple une API payante). On veut limiter chaque **IP** à **L requêtes par fenêtre de T secondes**.

Deux manières de contourner une limite mal faite :
1. **Plusieurs comptes** depuis la même IP. Réglé automatiquement si la clé de limitation est l'IP.
2. **Plusieurs sessions** depuis la même IP. Le load balancer les place sur des workers différents. Si chaque worker limite **localement**, la limite réelle devient `nb_workers × L`.

Solution réelle : un **Redis partagé** qui donne une **vision globale** de chaque IP, quels que soient le worker et le compte.

Dans le lab, on reproduit tout ça **en acteurs Elixir sur plusieurs nœuds BEAM**, et on implémente **deux modes** à comparer :
- **mode `:local`** : chaque worker a ses compteurs ; le contournement réussit (l'erreur naïve) ;
- **mode `:global`** : un acteur **Limiter** unique joue le rôle de Redis ; le contournement échoue.

---

## 3. Architecture

### 3.1 Flux d'une requête
```
Client (id, ip, compte, session)
   │ request
   ▼
LoadBalancer ── sticky session : une session reste sur le même worker
   │
   ▼
Worker Wi ──call check(ip)──▶ Limiter ── décision atomique allow/deny
   │  ◀──────────────────────
   ├─ si allow : call ──▶ API (ressource protégée, journalise chaque appel)
   └─ si deny  : répond 429 sans appeler l'API
   ▼
Client reçoit {:ok, résultat} ou {:error, 429}
```

### 3.2 Acteurs et nœuds

| Acteur | Nœud | Forme OTP | État | Rôle |
|---|---|---|---|---|
| Clients | `clients@` | process simples ou GenServer | id, ip, comptes, sessions | honnêtes (1 IP, 1 session) ou attaquants (1 IP, plusieurs comptes et sessions) |
| LoadBalancer | `clients@` | GenServer | table session → worker | répartit les sessions (round-robin), avec sticky sessions |
| Worker ×4 | `w1@` … `w4@` | GenServer | mode `:global` : rien ; mode `:local` : compteurs par (ip, fenêtre) | vérifier, puis appeler l'API |
| Limiter | `limiter@` | GenServer, nom global | compteurs par (ip, fenêtre) | décision atomique |
| API | `api@` | GenServer | journal des appels (ip, fenêtre, compte, worker) | ressource protégée et **oracle** des tests |
| Monitor (optionnel) | `clients@` | GenServer | stats | affichage / tableau de bord |
| Superviseurs | chaque nœud | Supervisor `:one_for_one` | enfants | redémarrer ce qui plante |

### 3.3 Messages

| Message | De → vers | Type | Justification |
|---|---|---|---|
| `{:request, client, session, compte, ip}` | Client → LB → Worker | call | le client attend une réponse |
| `{:check, ip}` | Worker → Limiter | **call** | le worker a besoin de la décision |
| `{:call_api, ip, compte}` | Worker → API | call | le worker renvoie le résultat au client |
| `{:decision, ip, fenetre, :allow / :deny}` | Limiter → Monitor | **cast** | simple notification, pas de réponse attendue |

### 3.4 Choix de conception (à savoir justifier)

- **Clé de limitation = IP**, ce qui neutralise le contournement multi-comptes.
- **Algorithme = fenêtre fixe** : `fenetre = div(temps, T)`. Accepter si `compteur(ip, fenetre) < L`, puis incrémenter. Défaut connu : jusqu'à 2L à cheval sur deux fenêtres.
- **Atomicité** : test **et** incrément dans **le même `handle_call`**. Un acteur traite un message à la fois, donc pas de race condition. C'est l'équivalent de `INCR` dans Redis.
- **Une seule horloge fait foi : celle du Limiter.** Les workers n'envoient aucun horodatage, donc pas de problème d'horloge globale. Utiliser une horloge locale du nœud Limiter ; demander à Claude la différence entre `System.monotonic_time` et `System.system_time` au moment venu.
- **Timeout du `call` vers le Limiter** avec une politique configurable :
  - **fail-closed** (par défaut) : répondre 429, on préserve la sûreté (C) ;
  - **fail-open** : laisser passer, on préserve la disponibilité (A). C'est le dilemme CAP.
- **Redémarrage conservateur du Limiter** : après un crash (état perdu), refuser tout jusqu'à la fin de la fenêtre en cours, pour ne jamais dépasser L.
- **Le Limiter est un SPOF et un goulot** : c'est assumé pour le Lab 1 (réplication au Lab 3).

---

## 4. Modèle de pannes (à annoncer explicitement)

| Composant | Panne | Traitement |
|---|---|---|
| Worker | crash | redémarré par son superviseur ; pas d'état important |
| Limiter | crash with recovery (perte de mémoire) | redémarrage conservateur |
| Liens entre nœuds | omission, partition | timeout, puis fail-closed ou fail-open |
| Temps | synchronie partielle | hypothèse cachée dans les timeouts |
| Byzantin | exclu | hors périmètre |

---

## 5. Propriétés

- **Sûreté** : pour toute IP et toute fenêtre, le nombre d'appels reçus par l'API ≤ L. Vraie en mode `:global` (avec fail-closed et redémarrage conservateur), fausse en mode `:local` dès qu'une IP a des sessions sur plusieurs workers.
- **Vivacité** : tout client finit par recevoir une réponse (résultat ou 429).
- **Cohérence** : le compteur du Limiter est **linéarisable** ; son point de linéarisation est le traitement du `check`.

---

## 6. Glossaire du cours (définitions courtes)

- **Système distribué** : composants qui coordonnent leurs actions *uniquement par messages* (Coulouris). Pas d'horloge globale, pannes indépendantes, connaissance partielle.
- **Acteur / process** : état privé, mailbox, traite un message à la fois, communique par messages.
- **call / cast** : requête avec réponse (référence unique et timeout) / sans réponse.
- **Nœud** : une instance de BEAM nommée ; plusieurs nœuds forment un cluster.
- **Superviseur, let it crash** : redémarrer plutôt que gérer chaque erreur.
- **Crash / crash with recovery** : arrêt définitif / redémarrage avec perte de la mémoire volatile.
- **Omission, partition** : messages perdus ; groupes de nœuds séparés.
- **Synchronie partielle** : bornes de délai qui existent mais sont inconnues. « Look for a timeout and you'll find it. »
- **Race condition** : résultat qui dépend de l'entrelacement (lire-lire-écrire-écrire).
- **Atomicité** : aucun état intermédiaire observable.
- **Linéarisabilité** : chaque opération semble se produire à un instant unique entre requête et réponse.
- **SPOF / goulot** : composant dont la panne fait tout tomber / par lequel tout passe.
- **Sûreté / vivacité** : rien de mauvais n'arrive jamais / quelque chose de bon finit par arriver.
- **CAP** : en cas de partition, choisir entre cohérence et disponibilité.
- **Invariant inter-acteurs** : propriété qui porte sur l'état de plusieurs acteurs (Liu et al. 2024). « ≤ L par IP » en est un en mode local.
- **Invariant inductif** : vrai à l'état initial et préservé par chaque action, donc toujours vrai.
- **Oracle** : ce qui décide si un test a réussi (ici, le journal de l'API).

---

## 7. Structure de projet suggérée

Un seul projet `mix` (créé avec `mix new rate_limiter --sup`). Les modules suivants sont une suggestion, à construire au fil des étapes :

```
lib/rate_limiter/
  limiter.ex        # GenServer : décision atomique
  worker.ex         # GenServer : check puis appel API ; modes :local / :global
  api.ex            # GenServer : ressource protégée et journal
  load_balancer.ex  # GenServer : sticky sessions
  client.ex         # clients honnêtes et attaquants
  cluster.ex        # démarrage automatique des nœuds (:peer)
  scenario.ex       # scénarios automatisés (charge et pannes)
test/
  ...               # tests unitaires puis tests distribués
spec/
  RateLimiter.tla   # spécification TLA+
  RateLimiterNaive.tla
```

---

## 8. Plan pas à pas

Chaque étape : **objectif**, **notions**, **résultat attendu**, **questions de vérification** (posées par Claude à la fin).

### Étape 0 : Installation et prise en main
- Installer Erlang/OTP et Elixir (idéalement via `asdf` ou le gestionnaire de paquets ; vérifier les versions compatibles).
- Découvrir `iex` : `h`, `i`, l'auto-complétion.
- ✅ `elixir --version` fonctionne ; je sais ouvrir et quitter `iex`.

### Étape 1 : Les bases du langage dans `iex`
- Notions : atomes, tuples, listes, maps, immuabilité, pattern matching, `case`, fonctions anonymes, modules, fonctions à plusieurs clauses, récursion, `Enum`, pipe `|>`.
- Mini-exercices : mettre à jour une map de compteurs `%{{ip, fenetre} => n}` ; écrire une fonction récursive.
- ✅ Je sais écrire un module avec deux fonctions et le tester dans `iex`.
- ❓ Pourquoi `=` n'est pas une affectation ? Comment « modifier » une map ?

### Étape 2 : Process bruts (le cours L02 à la main)
- Notions : `spawn`, `send`, `receive`, `after`, `self()`, PID, mailbox, réception sélective, `make_ref`.
- Refaire le **compteur de L02** (la récursion porte l'état), puis le **request/reply avec référence et timeout**.
- Expérience : envoyer un message « parasite » et voir que le `receive` filtré l'ignore.
- ✅ J'ai reconstruit un call avec timeout à la main.
- ❓ Qu'est-ce que le « gap » du cours ? Que prouve un timeout sur ce qui s'est passé côté serveur ?

### Étape 3 : Le Limiter en GenServer (un seul nœud)
- Notions : `use GenServer`, `init`, `handle_call`, `handle_cast`, valeurs de retour, `GenServer.call` / `GenServer.cast`, timeout.
- Implémenter la fenêtre fixe, avec la clé `{ip, fenetre}`.
- Premier test ExUnit séquentiel : L `allow` puis `deny`.
- ✅ Le Limiter fonctionne dans `iex`.
- ❓ Où est le point de linéarisation ? Pourquoi le test et l'incrément doivent-ils être dans le même `handle_call` ?

### Étape 4 : Worker, API et les deux modes (un seul nœud)
- Implémenter l'API (journal) et le Worker avec les modes `:local` et `:global`.
- Expérience de concurrence : lancer beaucoup de requêtes simultanées (par exemple avec `Task`) pour la même IP via plusieurs workers ; comparer ce que compte l'API dans chaque mode.
- ✅ Le mode local dépasse L, le mode global non.
- ❓ En termes de cours, pourquoi le mode local échoue-t-il ? (connaissance partielle, invariant inter-acteurs)

### Étape 5 : Supervision
- Notions : Supervisor, `child_spec`, `:one_for_one`, liens, moniteurs, let it crash, `Process.exit`.
- Tuer un worker, puis le Limiter, et observer le redémarrage (`:observer.start()`).
- Implémenter le **redémarrage conservateur** du Limiter.
- ✅ Après un crash du Limiter, on ne dépasse jamais L.
- ❓ Quel modèle de panne est le redémarrage d'un GenServer ? Qu'est-ce qui est perdu ?

### Étape 6 : Distribution manuelle (plusieurs terminaux)
- Notions : `iex --sname`, cookie, `Node.connect`, `Node.list`, nom global `{:global, :limiter}`, `:rpc` / démarrer un process à distance.
- Lancer à la main 1 Limiter, 1 API et 2 workers dans des terminaux séparés, et faire passer une requête.
- ✅ Une requête traverse 3 nœuds.
- ❓ Qu'est-ce qui change entre un envoi local et un envoi distant ? (illusion n°2 : la latence)

### Étape 7 : Clients, load balancer, scénario d'attaque
- Clients honnêtes et attaquant (1 IP, 2 comptes, 4 sessions) ; LB avec sticky sessions.
- ✅ Le scénario montre le contournement en mode local et son échec en mode global.

### Étape 8 : Automatisation du cluster
- Notions : le module OTP `:peer` (vérifier la version d'OTP), démarrer les nœuds depuis le code, charger le code sur les pairs.
- Une seule commande lance tout le cluster et un scénario qui tourne en continu.
- ✅ Plus besoin de terminaux multiples.

### Étape 9 : Pannes réseau et timeouts
- Timeout du `call` vers le Limiter ; politique fail-closed / fail-open configurable ; réponses tardives ignorées.
- Simuler : suspendre le Limiter (`:sys.suspend`), déconnecter un nœud (`Node.disconnect`).
- ✅ Chaque politique se comporte comme prévu.
- ❓ Relie fail-closed et fail-open au théorème CAP.

### Étape 10 : Tests distribués automatisés (livrable 2)
- ExUnit avec démarrage de nœuds dans les tests. Oracle : le journal de l'API.
- Tests minimum :
  - concurrence, même IP, 4 workers, avec pour oracle « exactement L » ;
  - mode local vs global ;
  - multi-comptes ;
  - crash d'un worker ;
  - crash du Limiter en milieu de fenêtre ;
  - partition ;
  - lenteur au-delà du timeout.
- Pièges : non-déterminisme (répéter les tests), fenêtre qui change pendant un test (T long ou temps contrôlé).
- ✅ `mix test` passe de façon reproductible.

### Étape 11 : Monitoring (optionnel)
- `:observer.start()` ; éventuellement Livebook + Kino pour un graphique live `allow`/`deny` par IP.

### Étape 12 : Spécification TLA+ (livrable 3)
- Notions : état, action, `Init`, `Next`, variables primées, bégaiement (stuttering), `[]`, `<>`, `~>`, équité faible, invariant, TLC.
- Modèle : `Send`, `Handle` (**une seule action**, qui traduit l'atomicité), `Receive`, `Tick`, puis `LimiterCrash`, `Drop`, `Timeout`.
- Propriétés : `TypeOK`, `Safety` (≤ L par IP et fenêtre), `Liveness`.
- Variantes :
  - le modèle **naïf** (Get et Set séparés), où TLC doit trouver la race ;
  - le modèle **local** (un compteur par worker), où TLC doit trouver 2L avec 2 workers.
- Invariant inductif : `count[ip] = nombre d'allow journalisés dans la fenêtre courante ∧ count ≤ L`.
- ✅ TLC valide le modèle global et trouve les contre-exemples des variantes.
- ❓ Pourquoi `Safety` seule n'est-elle pas inductive ?

### Étape 13 : Préparation de l'oral
- **Tout réexpliquer depuis zéro** (Matthieu n'a pas encore tout assimilé), puis poser toutes les questions ❓ des étapes 1 à 12 et celles du §9.
- Document qui réexplique tout le système : architecture, qui parle à qui, choix de conception, notions du cours, comment on l'a construit.
- Kit de démo : un fichier de commandes à copier-coller et/ou des scripts bash séparés, un par partie de la démo.
- ✅ Je peux présenter et lancer chaque démo sans réfléchir.

---

## 9. Ce que je dois pouvoir expliquer à la fin (auto-évaluation)

- Pourquoi c'est un système distribué et pas seulement parallèle.
- Pourquoi `check` est un call et `decision` un cast.
- Pourquoi deux workers ne peuvent pas faire dépasser L en mode global.
- Pourquoi le mode local échoue (connaissance partielle).
- Ce qui se passe si le Limiter plante, ou devient injoignable, et le lien avec CAP.
- Pourquoi une seule horloge suffit ici, et pourquoi ce ne serait plus vrai avec plusieurs Limiters.
- La preuve de sûreté par invariant inductif.
- Les limites (SPOF, goulot) et comment les labs 2 et 3 les traitent.

---

## 10. Suivi d'avancement

- [x] Étape 0 : installation
- [~] Étape 1 : bases du langage (partiel : types, immuabilité, pattern matching, `^`)
- [x] Étape 2 : process bruts
- [x] Étape 3 : Limiter GenServer
- [x] Étape 4 : Worker, API, modes local/global
- [x] Étape 5 : supervision, redémarrage conservateur
- [x] Étape 6 : distribution manuelle
- [x] Étape 7 : clients, LB, scénario d'attaque
- [x] Étape 8 : automatisation du cluster
- [x] Étape 9 : timeouts, fail-open/closed
- [x] Étape 10 : tests distribués
- [ ] Étape 11 : monitoring (optionnel)
- [x] Étape 12 : spécification TLA+
- [ ] Étape 13 : document oral + kit de démo

Notes de session :
- (Claude ajoute ici les décisions prises et les points que je n'ai pas encore bien compris.)
- 2026-09-27 — Étape 0 OK : Arch Linux, Elixir 1.20.2 / OTP 29 via pacman (paquet `erlang` complet, wx inclus pour `:observer`). Éditeur : nvim + LSP ; workflow `iex -S mix` dans un pane tmux + `recompile`.
- 2026-09-27 — Étape 1 écourtée à la demande de Matthieu (connaît OCaml) : vu types, immuabilité, `=` comme match, `^` pin, `case`, MatchError vs CaseClauseError. Pas encore vus : syntaxe `def`/`defp`/clauses multiples/gardes, `fn` + `.()`, `Enum`, `|>`, `Map.update` → à introduire au fil du code.
- 2026-09-28 — Étape 2 OK : `raw_limiter.ex` (loop récursif + `check` avec make_ref/^ref/after), timeout observé avec suspend_process + réponse tardive dans flush. Points qui ont bloqué : module ≠ process (check sexécute chez lappelant, loop chez le Limiter), rôle de `self()`, atome `:check` comme étiquette, `^`. Questions de vérification étapes 1-2 sautées → à reposer avant la soutenance.
- 2026-09-28 — Étape 3 OK : `limiter.ex` codé par Claude à la demande (GenServer, clé {ip, window}, monotonic_time, nom configurable pour les tests), branché dans application.ex (L=5, T=10s), `test/limiter_test.exs` (2 tests). Code d'entraînement déplacé dans `lab1/train/`. Tout le code est en anglais (cours en anglais).
- 2026-09-28 — Étape 4 OK : `api.ex` (journal = oracle), `worker.ex` (modes via clauses `decide/2`), `fixed_window.ex` (algo pur partagé Limiter/worker local). Expérience 100 req, 4 workers, L=5 : local → 20 appels API, global → 5. Workers pas encore supervisés (lancés à la main).
- 2026-09-28 — Étape 5 (code) : redémarrage conservateur option 1 (TOUT démarrage est traité comme une reprise après crash). Variante choisie : refus pendant `recovery_ms` = T complet depuis le démarrage (et non « jusqu'à la fin de la fenêtre en cours ») → reste sûr même si le nœud entier redémarre (horloge monotone réinitialisée). Option `recovery_ms: 0` pour les tests unitaires. 4 workers supervisés dans application.ex (`:worker_1`..`:worker_4`, mode via `Application.get_env(:rate_limiter, :mode, :global)`).
- 2026-09-28 — Étape 5 OK : kill Limiter → 429 pendant la reprise ; kill worker → redémarré ; arbre vu dans :observer (ajouté à extra_applications dans mix.exs).
- 2026-09-28 — Étape 6 OK : noms `{:global, Module}` pour Limiter et Api ; rôles par nœud via env `ROLE=limiter|api|worker` (défaut `all`), `LIMIT_MODE=local|global`. Testé : w1 → limiter → api sur 3 nœuds. Lancer les nœuds l'un après l'autre (lock de compilation mix).
- 2026-09-28 — Étape 7 OK (codé par Claude) : `load_balancer.ex` (round-robin + sticky, route seulement), `client.ex` (`run/4`, `attack/0`), rôle `clients`. Env renommée `LIMIT_MODE` (le script `elixir` écrase `MODE`). Résultats attaque 40 req : 1 nœud local → 15 (une session attaquante a partagé un worker avec l'honnête), 7 nœuds local → 20 = 4L, global → 5 = L. Honnête toujours 5/10.
- 2026-09-28 — Étape 8 OK : `cluster.ex` (`:peer.start_link` avec -pa code paths + env ROLE/LIMIT_MODE, puis `:erpc` ensure_all_started ; un process « holder » possède les pairs). `Cluster.demo(mode)` = une commande, attaque toutes les 10 s. Testé : local 20, global 5.
- 2026-09-28 — DEMANDE : un mode démo simple à lancer, qui montre en direct qui communique avec qui (client → LB → worker → limiter → api, allow/deny, pannes) pour que le public comprenne. À faire à l'étape 11 (remplace le monitoring optionnel).
- 2026-09-28 — Étape 9 OK : Worker catch `:exit` sur Limiter.check (timeout 200 ms) → politique `LIMIT_POLICY=fail_closed|fail_open`. Worker.request timeout 15 s (file d'attente d'un worker × timeout Limiter → timeouts en cascade sinon). Résultats (Limiter gelé OU nœud isolé) : fail_closed → 0 appel API ; fail_open → 40 pour l'attaquant (> L). Vu : `global` + prevent_overlapping_partitions transforme une partition partielle en partition franche. Raccourcis démo : Cluster.slow_limiter/resume_limiter/partition_limiter/heal.
- 2026-09-28 — Étape 9 (suite) : pairs `:peer` pilotés en `connection: :standard_io` (sinon couper la distribution tue le nœud) et lancés avec `-kernel prevent_overlapping_partitions false` (sinon `global` coupe en cascade, l'Api disparaît). Partition + heal testés : partition → 0 appel (fail_closed), heal → L.
- 2026-09-28 — Étape 10 OK : `test/distributed_test.exs`, 10 tests, un cluster `:peer` neuf par test, oracle = `Api.log`. Couvre : concurrence sur 4 workers = L, local = 4L, multi-comptes, honnête non impacté, crash worker, crash Limiter en milieu de fenêtre, partition fail_closed/fail_open, partition + heal, Limiter lent (réponses tardives = le « gap » : quota gaspillé mais sûr). 14/14 passent sur 4 seeds. Bug corrigé : `-kernel dist_auto_connect never` empêchait `global` de finir son maillage, donc `:global.sync` bloquait, le 1er cluster ne démarrait pas et ses nœuds orphelins cassaient tous les tests suivants. Option retirée ; la partition tient quand même (nom global désenregistré → personne n'envoie au nœud Limiter). Logs des pairs coupés via `-logger level`.
- 2026-09-28 — DÉCISION : plus de questions de vérification en fin d'étape (remplace la règle 6). Toutes les questions (étapes 1 à 12) sont regroupées dans l'étape 13, où Claude réexplique tout le système depuis zéro avant de les poser.
- 2026-09-29 — Étape 12 démarrée : `tools/tla2tools.jar` (TLC 2.19, Java 11) + lanceur `tools/tlc Spec.tla` (lit `Spec.cfg`). Mini-exemple `train/tla/Counter.tla` : garde `x < L` → OK ; sans garde → contre-exemple 0,1,2,3,4.
- 2026-09-29 — Étape 12 OK (tout codé par Claude à la demande, Matthieu n'a rien écrit → TOUT réexpliquer à l'étape 13). `rate_limiter/spec/` : `RateLimiter.tla` (Send/Handle/Receive/Timeout/Discard/Tick/Crash/DropReq/DropReply, variables clock/count/recovering/toLimiter/toWorker/wState/ref/wIp/apiLog), `RateLimiterNaive.tla` (Get/Set séparés), `RateLimiterLocal.tla` ; un `.cfg` par vérification ; `spec/check.sh` lance les 9 vérifs et compare au verdict attendu (~2 min, toutes PASS). `spec/check.sh -v <Cfg>` affiche la trace complète. Résultats : global fail_closed → Safety, IndInv, Liveness OK (619 k états, 3 workers, L=2) ; sanity → L atteignable ; IndInv inductif (86 k états de départ) ; Safety seule non inductive (CTI : 1 appel logué + 1 allow en vol, count=0) ; sans timeout → Liveness fausse (Crash vide la mailbox, attente infinie) ; fail_open → 3 appels pendant la reprise (CAP) ; naïf → les deux lisent 1, écrivent 2, 3 appels ; local → 4 workers atteignent 4L.
- À expliquer à l'étape 13 pour TLA+ : syntaxe (`/\`, `\/`, prime, garde, UNCHANGED, EXCEPT, `\E`), Init/Next/Spec, stuttering, `[]`/`~>`, équité faible (WF) et pourquoi elle est sur Timeout, lien action ↔ code Elixir, abstractions (fenêtres discrètes, reprise « jusqu'à fin de fenêtre » ⊇ code, appel API fusionné dans Receive, fenêtre = celle de l'allow), anti-vacuité, preuve par invariant inductif (Init ⇒ Inv, Inv ∧ Next ⇒ Inv', Inv ⇒ Safety) et le CTI, bornes MaxReq/MaxWindow + CHECK_DEADLOCK FALSE, limites (petit modèle ≠ preuve générale).
