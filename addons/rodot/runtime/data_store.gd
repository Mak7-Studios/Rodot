extends RefCounted

const Records = preload("local_saves.gd")
const DIRECTORY := "user://rodot/datastores"
const MAX_NAME_BYTES := 128
const MAX_SAFE_INTEGER := 9007199254740991

static func access(operation: String, args: Array) -> Variant:
	if args.size() < 2 or not valid_name(args[0]) or not valid_name(args[1]):
		return {"__error": "DataStore name and scope must be strings of 1 to 128 UTF-8 bytes"}
	if operation == "validate": return true
	if args.size() < 3 or not valid_name(args[2]):
		return {"__error": "DataStore keys must be strings of 1 to 128 UTF-8 bytes"}
	var path := DIRECTORY.path_join(JSON.stringify(args.slice(0, 3)).sha256_text() + ".json")
	var value = args[3] if args.size() > 3 else null
	if operation == "set": return _commit(path, value)
	var record = Records.read_record(path)
	if record is Dictionary and record.has("__error"): return record
	if record != null and (not record.revision is String or record.revision.is_empty()):
		return {"__error": "DataStore entry has an invalid revision"}
	match operation:
		"get": return record
		"remove":
			if record == null: return null
			var result := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			if result != OK: return {"__error": "Could not remove DataStore key: " + error_string(result)}
			return record
		"increment":
			var previous = record.data if record != null else 0
			var delta = 1 if value == null else value
			if not _safe_integer(previous) or not _safe_integer(delta) or not _safe_integer(previous + delta):
				return {"__error": "IncrementAsync requires integers within Luau's exact number range"}
			var next := int(previous) + int(delta)
			var result = _commit(path, next)
			return result if result is Dictionary else next
		"compare_and_set":
			var revision := str(record.revision) if record != null else ""
			if args.size() < 5 or not args[4] is String: return {"__error": "Expected a DataStore revision"}
			if revision != args[4]: return false
			return _commit(path, value)
	return {"__error": "Unknown DataStore operation: " + operation}

static func valid_name(value: Variant) -> bool:
	return value is String and not value.is_empty() and value.to_utf8_buffer().size() <= MAX_NAME_BYTES

static func _safe_integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(value) and absf(value) <= MAX_SAFE_INTEGER and floor(value) == value

static func _commit(path: String, value: Variant) -> Variant:
	var revision := Crypto.new().generate_random_bytes(16).hex_encode()
	var result = Records.write_record(path, value, revision)
	return result if result is Dictionary else revision
