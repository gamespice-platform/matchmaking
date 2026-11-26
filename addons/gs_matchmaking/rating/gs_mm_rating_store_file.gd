class_name GSMmRatingStoreFile
extends GSMmRatingStore

## Ratings in one JSON file, written atomically.
##
## For a community running its own ranked server with no backbone. Written to a temporary
## file and renamed over the old one, because a process killed half way through a write is
## the moment a rating file is most likely to be written — at the end of a match — and a
## truncated file is every player on the server starting from 1500 again.

const CHANNEL := "matchmaking.store"
## gs-core's level whose GSPaths.write_bytes writes through a per-writer temporary.
const ATOMIC_CORE_LEVEL := 49

var path: String = "user://matchmaking/ratings.json"


func _init(p_path: String = "") -> void:
	if p_path != "":
		path = p_path


func open() -> GSResult:
	if not FileAccess.file_exists(path):
		return GSResult.success(0)
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return GSResult.fail(GSError.CODE_PARSE, "The ratings file is not a JSON object.", path)
	return load_dict(parsed as Dictionary)


func put(player_id: String, playlist: StringName, rating: GSMmRating) -> GSResult:
	var res := super.put(player_id, playlist, rating)
	if not res.ok:
		return res
	return save()


## Logged here, because the in-memory rating has already changed by the time this runs
## and the caller -- GSMatchmaker.report_result -- returns the failure part-way through
## a match without a line. ERROR: the ratings on disk are now behind the ones in force,
## and a restart puts those players back where they were.
func save() -> GSResult:
	var res := _write()
	if not res.ok:
		GSLog.error(CHANNEL, "ratings were not written", {
			"path": path,
			"code": res.code(),
			"error": res.error.message if res.error != null else "",
		})
	return res


## Whether this build's GSPaths.write_bytes gives every writer its own temporary (gs-core API 49).
## Two writers of one ratings file (two servers on one host, a worker thread) shared a fixed
## [code]<path>.tmp[/code]: the second truncated it under the first's rename, and a reader got half a file.
static func core_writes_atomically() -> bool:
	return GSAddonApi.build_level("gs_core") >= ATOMIC_CORE_LEVEL


func _write() -> GSResult:
	var text := JSON.stringify(to_dict(), "\t", true)
	if core_writes_atomically():
		var written := GSPaths.write_text(path, text)
		return GSResult.success(null) if written.ok else written
	return _write_shared_tmp(text)


## The write before gs-core API 49: a fixed temporary, so two writers at once can tear it.
func _write_shared_tmp(text: String) -> GSResult:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return GSResult.failure(GSError.from_engine(made, "creating " + dir))

	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return GSResult.failure(GSError.from_engine(FileAccess.get_open_error(), tmp))
	f.store_string(text)
	f.close()

	var moved := DirAccess.rename_absolute(tmp, path)
	if moved != OK:
		return GSResult.failure(GSError.from_engine(moved, "replacing " + path))
	GSWeb.sync_filesystem()
	return GSResult.success(null)
