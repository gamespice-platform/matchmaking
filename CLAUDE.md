# GameSpice Matchmaking

Who plays whom: Glicko-2 ratings per queue, a queue whose tolerances widen with waiting, parties placed whole, balanced sides, an accept step, a server to play on, and a result that moves the ratings. The site rates too: results go up through website-city's `rating/*` routes and the ratings come back.

Read the family [CLAUDE.md](../../CLAUDE.md) first, and [docs/backbone.md](../../docs/backbone.md) for anything that talks to website-city.

**The distributable is `addons/gs_matchmaking/`.** It requires [GameSpice Core](../gs-core) and nothing else (`ln -s ../../gs-core/addons/gs_core addons/gs_core`, gitignored). gs-auth's `GSBackboneClient` is reached by duck typing (`post_integration`, `get_integration`). gs-server-deploy hosts a `GSMatchmaker` when its matchmaking config enables one.

## Read before

| Read | Before |
| --- | --- |
| [docs/backbone-contract.md](docs/backbone-contract.md) | changing a request, a check before sending, or retry: the three routes, their scopes and shapes, the rule both sides implement, what a 404 means, rating parity |
| [docs/design.md](docs/design.md) | changing the rating, the queue, the balancer or the accept step: the team extension, oldest first, party rating, whole tickets, the synchronous store, refusing what the site would refuse, what is deliberately not here |

## Layout

| Path | What |
| --- | --- |
| `rating/gs_mm_rating.gd` | `GSMmRating`: rating, deviation, volatility, games, last played; `conservative()` is what a board shows |
| `rating/gs_mm_glicko2.gd` | `GSMmGlicko2`: the update (the paper, step for step), `age()`, `expected()`, `rate_match()` for teams |
| `rating/gs_mm_rating_store.gd`, `_file.gd` | `GSMmRatingStore` (keyed by player and playlist, synchronous), `GSMmRatingStoreFile` (temp file and rename) |
| `queue/gs_mm_playlist.gd` | `GSMmPlaylist`: one queue's shape, party cap, widening tolerances, `validate` with the site's id rule |
| `queue/gs_mm_ticket.gd` | `GSMmTicket`: a solo player or a party, the unit of placement |
| `queue/gs_mm_balance.gd` | `GSMmBalance`: whole tickets into sides, deterministic |
| `queue/gs_mm_queue.gd`, `gs_mm_match.gd` | `GSMmQueue` (the pure `form(now)`), `GSMmMatch` (a found match with its explanation) |
| `runtime/gs_matchmaker.gd` | `GSMatchmaker`: queues, passes, accept / decline / timeout, `allocator`, `report_result` |
| `runtime/gs_mm_allocator_list.gd` | `GSMmAllocatorList`: a fixed server list, one match per server |
| `net/gs_mm_backbone.gd` | `GSMmBackbone`: `define`, `submit`, `refresh`, `flush`, and the pre-send checks |
| `gs_matchmaking_config.gd` | `GSMatchmakingConfig`: rating rules (`tau`, inactivity period, participation, leavers) |
| `examples/matchmaking_selftest.tscn` | the suite: no network, no wall clock |
| `examples/cfg_selftest.tscn` | `matchmaking.yml` through `GSMatchmakingConfig.load_cfg`: `cfg/addons/gs_matchmaking/`, `cfg/server/addons/gs_matchmaking/` over it, the flat `cfg/matchmaking.yml` shim (WARN once, removed 2026-12-31) |

Paths except `examples/` are in `addons/gs_matchmaking/`.

## Running and testing

The family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/matchmaking_selftest.tscn`. Section 1 (the paper's worked example, exact figures to 0.001) is the one to keep: every other check compares ratings with each other and would pass against an arithmetic slip. The suite is the only thing that has exercised the queue; nothing here has been found by a real queue under load or a real client. A change to a request shape wants a run against a dev site.

## Rules that bite

- `rate_match` shifts the opponent by the player's gap to their own side's mean; never rate against the other side's mean alone. [design](docs/design.md#the-team-extension-shifts-the-opponent-not-the-player)
- The anchor is the oldest ticket, but each candidate is held to its own latency ceiling. [design](docs/design.md#oldest-first-and-each-tickets-own-latency-ceiling)
- Parties are placed whole and rated toward their best player. [design](docs/design.md#a-partys-matching-rating-leans-to-its-best-player)
- A decline cools down only the decliner; everyone else keeps their `enqueued_at`; no free server cools down nobody. [design](docs/design.md#the-accept-step-keeps-everybodys-place)
- `enqueue` takes ids, never ratings; the rating store stays synchronous. [design](docs/design.md#ratings-come-from-the-store-and-the-store-is-synchronous)
- The site rates; `submit` sends results, never numbers. A change to the rule changes the site's `src/types/rating/glicko2.ts` in the same breath, and both test the same worked example. [contract](docs/backbone-contract.md#the-rule-the-site-must-implement-and-duplicate)
- Anything the site would 400 is refused before sending (`define_problem`, `submit_problem`, `config_problem`, `GSMmPlaylist.validate`); player keys are scope keys, never `backbone:…`. [contract](docs/backbone-contract.md#what-the-game-checks-before-sending)
- A `No playlist` 404 re-declares that one queue once and resubmits; a refused body is dropped from the retry queue (`is_refused`), a 401/403 or missing route stops `flush`. [contract](docs/backbone-contract.md#what-a-404-means)
- Parenthesise bitwise tests: GDScript binds `&` tighter than `==`. [design](docs/design.md#balancing-places-whole-tickets)

Deliberately not here: backfill, short matches, role queues, an orchestrator, where the service runs. [design](docs/design.md#deliberately-not-here)
