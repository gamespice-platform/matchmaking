extends RefCounted

## matchmaking_selftest's section on writing the ratings file while others write and read it.
## Its own file for the suite's 800-line budget. [param t] is the suite: its _section and _check count.

const DIR := "user://mm_selftest_atomic"
const WRITERS := 4
const ROUNDS := 30
const PLAYERS := 200


static func run(t: Node) -> void:
	t._section("The ratings file is whole to a reader while four writers replace it")
	GSPaths.remove_tree(DIR)
	var path := DIR + "/ratings.json"

	t._check(GSMmRatingStoreFile.core_writes_atomically(), "gs-core here is API 49 or later, so the store writes through GSPaths")

	var stores: Array[GSMmRatingStoreFile] = []
	for i in WRITERS:
		var s := GSMmRatingStoreFile.new(path)
		# Enough players that a write takes long enough to be overlapped.
		var players := {}
		for p in PLAYERS:
			players["duel|p%d" % p] = {"rating": 1500.0 + i}
		s.load_dict(players)
		stores.append(s)
	t._check(stores[0].save().ok, "a first write lands")

	var failed := [0]
	var writer := func(i: int) -> void:
		for _r in ROUNDS:
			if not stores[i].save().ok:
				failed[0] += 1
	var group := WorkerThreadPool.add_group_task(writer, WRITERS)
	var reads := 0
	var torn := 0
	while not WorkerThreadPool.is_group_task_completed(group):
		var back := GSMmRatingStoreFile.new(path)
		reads += 1
		if not back.open().ok or back.count() != PLAYERS:
			torn += 1
	WorkerThreadPool.wait_for_group_task_completion(group)

	t._check(failed[0] == 0, "every one of %d writes succeeded (%d failed)" % [WRITERS * ROUNDS, failed[0]])
	t._check(reads > 0 and torn == 0, "%d reads during the writes, none missing or torn (%d were)" % [reads, torn])
	var left := Array(DirAccess.get_files_at(DIR)).filter(func(f: String) -> bool: return f.ends_with(".tmp"))
	t._check(left.is_empty(), "no temporary is left beside the file: %s" % [left])

	# The pre-49 path still writes a whole file for a build with an older gs-core.
	DirAccess.remove_absolute(path)
	var old := GSMmRatingStoreFile.new(path)
	old.load_dict({"duel|legacy": {"rating": 1650.0}})
	var res := old._write_shared_tmp(JSON.stringify(old.to_dict(), "\t", true))
	var reread := GSMmRatingStoreFile.new(path)
	t._check(res.ok and reread.open().ok and reread.fetch("legacy", &"duel").rating == 1650.0,
			"the fallback for gs-core before 49 still round-trips")
	GSPaths.remove_tree(DIR)
