class_name GSMatchmaker
extends Node

## The matchmaking service: queues, the accept step, placing a match on a server, and
## rating the result.
##
## [b]Where it runs is a deployment decision, not this node's.[/b] It holds no socket.
## A dedicated lobby server runs it and feeds it tickets from connected players; a hub
## process runs it for a fleet; the backbone will run the same rules in its own language.
## Everything reaches it through methods and leaves through signals, so all three are the
## same node with different callers — and the suite is a fourth.
##
## [b]Tickets are built from ids, not from ratings a client sent.[/b] [method enqueue]
## takes player ids and looks their ratings up in [member store]. A client that could
## send its own rating could send any rating, and a matchmaker that believed it would be
## the easiest smurfing tool ever shipped.
##
## [b]Parties come in whole.[/b] GameSpice Party is not a dependency and nothing here names it:
## a party is a ticket with several ids on it and a [code]party_id[/code] that rides
## through to the result. See [method enqueue].
##
## No autoload. Registers itself under [constant SERVICE], scoped if two run in one process.

const CHANNEL := "matchmaking"
const SERVICE := &"gs_matchmaker"

## A ticket entered a queue.
signal queued(ticket: GSMmTicket)
## A ticket left a queue without being matched: cancelled, or dropped by a failed accept.
signal left_queue(ticket_id: String, reason: String)
## A match was found and is waiting for everybody to accept it.
signal match_found(m: GSMmMatch, deadline: float)
## Somebody accepted. [param accepted] of [param total] have.
signal match_accepted(match_id: String, player_id: String, accepted: int, total: int)
## A found match fell through. [param requeued] went back in at their original place.
signal match_cancelled(m: GSMmMatch, reason: String, requeued: PackedStringArray)
## Everybody accepted and the match has somewhere to be played.
signal match_ready(m: GSMmMatch)
## Ratings moved after a result was filed. player id -> {before, after}.
signal ratings_changed(playlist: StringName, changes: Dictionary)

@export var config: GSMatchmakingConfig = null

@export var playlists: Array[GSMmPlaylist] = []

## Suffix for the registry name, when more than one matchmaker shares a process.
@export var service_scope: StringName = &""

## Where ratings come from and go to. Defaults to a file at [member GSMatchmakingConfig.ratings_file].
var store: GSMmRatingStore = null

## Places a ready match on a server. Anything with [code]allocate(m: GSMmMatch) -> GSResult[/code];
## the result's value, a Dictionary, becomes [member GSMmMatch.allocation]. See
## [GSMmAllocatorList]. With none, a ready match carries no allocation and the caller
## decides where it goes.
var allocator: Object = null

## Unix seconds. Replaced by the suite so it can wait ten minutes in a millisecond.
var clock_fn: Callable = func() -> float: return Time.get_unix_time_from_system()

## playlist id -> GSMmQueue
var _queues: Dictionary = {}

## match id -> {m, deadline, accepted: Dictionary player -> true}
var _pending: Dictionary = {}

## player id -> Unix seconds until which they may not queue.
var _cooldowns: Dictionary = {}

var _since_pass: float = 0.0
var _started: bool = false
## Rate limit for the search-budget warning: last warn (msec) and exhaustions since it.
var _budget_warn_ms: int = -1
var _budget_seen: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var res := setup()
	if not res.ok:
		GSLog.error(CHANNEL, "matchmaker did not start", {"detail": str(res.error)})


func _exit_tree() -> void:
	GSRegistry.unregister_instance(_service_name(), self)


## Builds the queues. Called by [method _ready]; callable earlier by a caller that wants
## the error rather than a log line.
func setup() -> GSResult:
	if _started:
		return GSResult.success(null)
	if config == null:
		config = GSMatchmakingConfig.new()
	var valid := config.validate()
	if not valid.ok:
		return valid.wrap("matchmaking config")

	if store == null:
		var file := GSMmRatingStoreFile.new(config.ratings_file)
		var opened := file.open()
		if not opened.ok:
			# Refuse rather than start empty. A ranked server that silently reset everybody
			# to 1500 because a file did not parse is worse than one that did not start.
			return opened.wrap("ratings")
		store = file

	for pl in playlists:
		var added := add_playlist(pl)
		if not added.ok:
			return added

	GSRegistry.register(_service_name(), self)
	_started = true
	GSLog.info(CHANNEL, "matchmaker ready", {"queues": _queues.size(), "ratings": store.count()})
	return GSResult.success(null)


func add_playlist(pl: GSMmPlaylist) -> GSResult:
	if pl == null:
		return GSResult.fail(GSError.CODE_INVALID, "a null playlist")
	var valid := pl.validate()
	if not valid.ok:
		return valid
	if _queues.has(pl.id):
		return GSResult.fail(GSError.CODE_CONFLICT, "two playlists with one id", String(pl.id))
	_queues[pl.id] = GSMmQueue.new(pl)
	if not playlists.has(pl):
		playlists.append(pl)
	return GSResult.success(null)


func queue_for(playlist_id: StringName) -> GSMmQueue:
	return _queues.get(playlist_id)


func _process(delta: float) -> void:
	if not _started:
		return
	_since_pass += delta
	if _since_pass < config.pass_interval_sec:
		return
	_since_pass = 0.0
	run_pass()


# --- Queueing ----------------------------------------------------------------

## Queues [param player_ids] together. One id is a solo player; several are a party that
## will be placed whole.
##
## [param member_latencies] is one [code]{region: ms}[/code] per member, in the same order,
## as each client measured it. They are folded to the worst per region here — see
## [GSMmTicket] — so a region one member cannot reach is not offered to the party.
func enqueue(ticket_id: String, playlist_id: StringName, player_ids: PackedStringArray,
		member_latencies: Array, party_id: String = "") -> GSResult:
	var q := queue_for(playlist_id)
	if q == null:
		return GSResult.fail(GSError.CODE_INVALID, "There is no such queue.", String(playlist_id))
	if player_ids.is_empty():
		return GSResult.fail(GSError.CODE_INVALID, "a ticket with nobody on it")
	if member_latencies.size() != player_ids.size():
		return GSResult.fail(
			GSError.CODE_INVALID,
			"every member needs latencies",
			"%d members, %d latency reports" % [player_ids.size(), member_latencies.size()]
		)
	if config.max_tickets > 0 and _ticket_count() >= config.max_tickets:
		return GSResult.fail(GSError.CODE_RATE_LIMITED, "Matchmaking is full right now. Try again shortly.")

	var now := _now()
	for pid in player_ids:
		var until := float(_cooldowns.get(pid, 0.0))
		if until > now:
			var err := GSError.make(
				GSError.CODE_RATE_LIMITED,
				"Somebody on this ticket recently declined a match.",
				pid
			)
			err.retry_after = until - now
			return GSResult.failure(err)
		if _in_any_queue(pid) != "":
			return GSResult.fail(GSError.CODE_CONFLICT, "Somebody on this ticket is already queued.", pid)
		if _in_pending(pid) != "":
			return GSResult.fail(GSError.CODE_CONFLICT, "Somebody on this ticket has a match waiting.", pid)

	var members := []
	for pid in player_ids:
		members.append({"id": pid, "rating": rating_of(pid, playlist_id, now)})

	var t := GSMmTicket.party(ticket_id, playlist_id, members, member_latencies, now, party_id)
	var added := q.add(t)
	if not added.ok:
		return added
	GSLog.debug(CHANNEL, "queued", {"ticket": ticket_id, "queue": String(playlist_id), "size": t.size()})
	queued.emit(t)
	return GSResult.success(t)


func cancel(ticket_id: String) -> bool:
	for q in _queues.values():
		if (q as GSMmQueue).remove(ticket_id) != null:
			left_queue.emit(ticket_id, "cancelled")
			return true
	return false


## The rating a player is matched on now: the stored one, widened for any absence.
func rating_of(player_id: String, playlist_id: StringName, now: float = -1.0) -> GSMmRating:
	if now < 0.0:
		now = _now()
	var r := store.fetch(player_id, playlist_id)
	if r.last_played <= 0:
		return r
	var period := config.inactivity_period_days * 86400.0
	return GSMmGlicko2.age(r, (now - r.last_played) / period)


# --- Passes and the accept step ----------------------------------------------

## One pass over every queue, plus expiring accept steps. Returns the matches found.
func run_pass() -> Array:
	var now := _now()
	_expire_pending(now)

	var found := []
	for q in _queues.values():
		var queue: GSMmQueue = q
		var formed := queue.form(now)
		_note_budget(queue)
		for m_v in formed:
			var m: GSMmMatch = m_v
			found.append(m)
			GSLog.info(CHANNEL, "match found", m.describe())
			if queue.playlist.accept_timeout_sec <= 0.0:
				_finish(m)
			else:
				var deadline := now + queue.playlist.accept_timeout_sec
				_pending[m.id] = {"m": m, "deadline": deadline, "accepted": {}}
				match_found.emit(m, deadline)
	return found


func _note_budget(queue: GSMmQueue) -> void:
	var id := String(queue.playlist.id)
	var before: int = _budget_seen.get(id, 0)
	if queue.budget_exhausted == before:
		return
	var now_ms := Time.get_ticks_msec()
	if _budget_warn_ms >= 0 and now_ms - _budget_warn_ms < 10000:
		return
	_budget_warn_ms = now_ms
	_budget_seen[id] = queue.budget_exhausted
	GSLog.warn(CHANNEL, "search budget ran out; anchors left waiting (raise playlist search_budget, 0 = unlimited)",
		{"playlist": id, "since_warning": queue.budget_exhausted - before, "search_budget": queue.playlist.search_budget})


func accept(match_id: String, player_id: String) -> GSResult:
	var p: Dictionary = _pending.get(match_id, {})
	if p.is_empty():
		return GSResult.fail(GSError.CODE_STATE, "That match is no longer waiting.", match_id)
	var m: GSMmMatch = p["m"]
	if not m.player_ids().has(player_id):
		return GSResult.fail(GSError.CODE_FORBIDDEN, "You are not in that match.", player_id)
	var accepted: Dictionary = p["accepted"]
	accepted[player_id] = true
	var total := m.player_ids().size()
	match_accepted.emit(match_id, player_id, accepted.size(), total)
	if accepted.size() >= total:
		_pending.erase(match_id)
		_finish(m)
	return GSResult.success(accepted.size())


## Declining ends the match for everybody. The decliner's ticket leaves; the rest go back.
func decline(match_id: String, player_id: String) -> GSResult:
	var p: Dictionary = _pending.get(match_id, {})
	if p.is_empty():
		return GSResult.fail(GSError.CODE_STATE, "That match is no longer waiting.", match_id)
	var m: GSMmMatch = p["m"]
	if not m.player_ids().has(player_id):
		return GSResult.fail(GSError.CODE_FORBIDDEN, "You are not in that match.", player_id)
	_pending.erase(match_id)
	var guilty := {player_id: true}
	_fall_through(m, guilty, "declined")
	return GSResult.success(null)


func _expire_pending(now: float) -> void:
	for id in _pending.keys():
		var p: Dictionary = _pending[id]
		if float(p["deadline"]) > now:
			continue
		_pending.erase(id)
		var m: GSMmMatch = p["m"]
		var accepted: Dictionary = p["accepted"]
		var guilty := {}
		for pid in m.player_ids():
			if not accepted.has(pid):
				guilty[pid] = true
		_fall_through(m, guilty, "not everybody accepted")


## Tickets with nobody guilty on them go back in at their original time; tickets with
## somebody guilty leave, and the guilty wait out the cooldown.
##
## [b]A whole party leaves if one member did not accept.[/b] Requeueing the rest of it
## would split it, which is the one thing the queue promises never to do.
func _fall_through(m: GSMmMatch, guilty: Dictionary, reason: String) -> void:
	var now := _now()
	var requeued := PackedStringArray()
	for t_v in m.tickets():
		var t: GSMmTicket = t_v
		var bad := false
		for pid in t.member_ids():
			if guilty.has(pid):
				bad = true
		if bad:
			var pl := (queue_for(t.playlist) as GSMmQueue).playlist
			for pid in t.member_ids():
				if guilty.has(pid):
					_cooldowns[pid] = now + pl.decline_cooldown_sec
			left_queue.emit(t.id, reason)
			continue
		# Original enqueued_at is kept on the ticket, so this is a return to the front.
		var q: GSMmQueue = queue_for(t.playlist)
		if q.add(t).ok:
			requeued.append(t.id)
	GSLog.info(CHANNEL, "match fell through", {"match": m.id, "reason": reason, "requeued": requeued.size()})
	match_cancelled.emit(m, reason, requeued)


func _finish(m: GSMmMatch) -> void:
	if allocator != null and allocator.has_method("allocate"):
		var res: Variant = await allocator.call("allocate", m)
		if res is GSResult and not (res as GSResult).ok:
			# Nobody did anything wrong, so nobody is cooled down: everybody goes back in.
			GSLog.warn(CHANNEL, "no server for a match", {"match": m.id, "detail": str((res as GSResult).error)})
			_fall_through(m, {}, "no server was free")
			return
		if res is GSResult and (res as GSResult).value is Dictionary:
			m.allocation = (res as GSResult).value
	match_ready.emit(m)


# --- Results -----------------------------------------------------------------

## Files a finished match and moves everybody's rating.
##
## [param sides] is one Array of player ids per side, [param placements] each side's place
## (lower is better, equal is a draw). [param participation], optional, is player id ->
## 0..1 of the match they were present for. [param leavers] left early; with
## [member GSMatchmakingConfig.leaver_takes_loss] they are rated as having lost outright.
##
## Returns player id -> {before, after} for everybody rated. An unranked playlist rates
## nobody and returns an empty Dictionary, which is success.
func report_result(playlist_id: StringName, sides: Array, placements: Array,
		participation: Dictionary = {}, leavers: PackedStringArray = PackedStringArray()) -> GSResult:
	var q := queue_for(playlist_id)
	if q == null:
		return GSResult.fail(GSError.CODE_INVALID, "There is no such queue.", String(playlist_id))
	if sides.size() != placements.size() or sides.size() < 2:
		return GSResult.fail(GSError.CODE_INVALID, "one placement per side, and at least two sides")
	if not q.playlist.ranked:
		return GSResult.success({})

	var now := _now()
	var teams := []
	var weights := []
	var worst := 0
	for p in placements:
		worst = maxi(worst, int(p))
	for side in sides:
		var ratings := []
		var w := []
		for pid in side:
			ratings.append(rating_of(str(pid), playlist_id, now))
			var part := clampf(float(participation.get(str(pid), 1.0)), 0.0, 1.0)
			if leavers.has(str(pid)) and config.leaver_takes_loss:
				part = 1.0
			elif part < config.min_participation:
				part = 0.0
			w.append(part)
		teams.append(ratings)
		weights.append(w)

	var rated := GSMmGlicko2.rate_match(teams, placements, weights, config.tau)

	# A leaver is re-rated with their own side placed last, and only their row is kept.
	if config.leaver_takes_loss and not leavers.is_empty():
		for i in range(sides.size()):
			var side: Array = sides[i]
			var has_leaver := false
			for pid in side:
				if leavers.has(str(pid)):
					has_leaver = true
			if not has_leaver:
				continue
			var worse := placements.duplicate()
			worse[i] = worst + 1
			var as_lost := GSMmGlicko2.rate_match(teams, worse, weights, config.tau)
			for k in range(side.size()):
				if leavers.has(str(side[k])):
					(rated[i] as Array)[k] = (as_lost[i] as Array)[k]

	var changes := {}
	for i in range(sides.size()):
		var side: Array = sides[i]
		for k in range(side.size()):
			var pid := str(side[k])
			var before: GSMmRating = (teams[i] as Array)[k]
			var after: GSMmRating = (rated[i] as Array)[k]
			if float((weights[i] as Array)[k]) <= 0.0:
				continue
			after.last_played = int(now)
			var put := store.put(pid, playlist_id, after)
			if not put.ok:
				return put.wrap("storing %s" % pid)
			changes[pid] = {"before": before, "after": after}

	GSLog.info(CHANNEL, "match rated", {"queue": String(playlist_id), "players": changes.size()})
	ratings_changed.emit(playlist_id, changes)
	return GSResult.success(changes)


# --- Introspection -----------------------------------------------------------

func pending_count() -> int:
	return _pending.size()


func describe_lines() -> PackedStringArray:
	var now := _now()
	var out := PackedStringArray()
	out.append("matchmaker: %d queues, %d tickets, %d awaiting accept, %d ratings" % [
		_queues.size(), _ticket_count(), _pending.size(), store.count() if store != null else 0,
	])
	for q in _queues.values():
		out.append_array((q as GSMmQueue).describe_lines(now))
	return out


func _ticket_count() -> int:
	var n := 0
	for q in _queues.values():
		n += (q as GSMmQueue).size()
	return n


func _in_any_queue(player_id: String) -> String:
	for q in _queues.values():
		var t := (q as GSMmQueue).ticket_of_player(player_id)
		if t != "":
			return t
	return ""


func _in_pending(player_id: String) -> String:
	for id in _pending:
		var m: GSMmMatch = (_pending[id] as Dictionary)["m"]
		if m.player_ids().has(player_id):
			return str(id)
	return ""


func _now() -> float:
	return float(clock_fn.call())


func _service_name() -> StringName:
	if service_scope == &"":
		return SERVICE
	return GSRegistry.scoped_name(SERVICE, service_scope)
