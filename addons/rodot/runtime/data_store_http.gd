extends RefCounted

const Stores = preload("data_store.gd")
const SupabaseConfig = preload("supabase_config.gd")
const ROOT := "rodot/datastores/"
const DEFAULT := ROOT + "default_backend"
const NAMESPACE := ROOT + "namespace"
const MANUAL := ROOT + "manual_url"
const SUPABASE := SupabaseConfig.URL
const BODY_LIMIT := 2 * 1024 * 1024 + 16384
const MAX_REQUESTS := 32

var _serial := 0
var _pending := 0

func start(owner: Node, backend: int, operation: String, args: Array, complete: Callable) -> Variant:
	var validation = Stores.access("validate", args)
	if validation is Dictionary: return validation
	if args.size() < 3 or not Stores.valid_name(args[2]): return {"__error": "Invalid DataStore key"}
	if operation not in ["get", "set", "increment", "remove", "compare_and_set"]: return {"__error": "Unknown DataStore operation"}
	if _pending >= MAX_REQUESTS: return {"__error": "Too many remote DataStore requests are running"}
	var project: String = ProjectSettings.get_setting(NAMESPACE, "")
	if project.is_empty(): project = str(ProjectSettings.get_setting("application/config/name", "Rodot"))
	if not Stores.valid_name(project): return {"__error": "Set a valid Rodot DataStore namespace in Project Settings"}
	var payload := {"op": operation, "project": project, "store": args[0], "scope": args[1], "key": args[2]}
	if args.size() > 3: payload.value = args[3]
	if args.size() > 4: payload.revision = args[4]
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	var url: String = ProjectSettings.get_setting(SUPABASE if backend == 2 else MANUAL, "")
	url = url.strip_edges()
	if not _valid_url(url): return {"__error": "Set a HTTPS DataStore URL in Project Settings. HTTP is available on localhost."}
	if backend == 2:
		var base := SupabaseConfig.origin(url)
		if base.is_empty():
			return {"__error": "Supabase URL must be the project origin"}
		url = base + "/rest/v1/rpc/rodot_datastore"
		var key := SupabaseConfig.key_for(base)
		if not SupabaseConfig.valid_key(key):
			return {"__error": "Set the project key in Project > Tools > Rodot Supabase Setup, or set RODOT_SUPABASE_SECRET_KEY on your server"}
		headers.append("apikey: " + key)
		if not key.begins_with("sb_secret_"): headers.append("Authorization: Bearer " + key)
		payload = {"request": payload}
	else:
		var token := OS.get_environment("RODOT_DATASTORE_TOKEN").strip_edges()
		if not token.is_empty():
			if not _valid_header(token): return {"__error": "Invalid manual DataStore token"}
			headers.append("Authorization: Bearer " + token)
	var body := JSON.stringify(payload, "", true, true)
	if body.to_utf8_buffer().size() > BODY_LIMIT: return {"__error": "Remote DataStore request exceeds the size limit"}
	var request := HTTPRequest.new()
	request.timeout = 15.0
	request.body_size_limit = BODY_LIMIT
	request.max_redirects = 0
	request.process_mode = Node.PROCESS_MODE_ALWAYS
	owner.add_child(request, false, Node.INTERNAL_MODE_FRONT)
	_serial += 1
	var id := _serial
	request.request_completed.connect(func(result, status, _headers, bytes):
		_pending -= 1
		request.queue_free()
		if complete.is_valid(): complete.call(id, _reply(operation, result, status, bytes))
	, CONNECT_ONE_SHOT)
	var error := request.request(url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		request.queue_free()
		return {"__error": "Could not start remote DataStore request: " + error_string(error)}
	_pending += 1
	return id

static func _valid_header(value: String) -> bool:
	return not value.is_empty() and not value.contains("\r") and not value.contains("\n")

static func _valid_url(url: String) -> bool:
	if not _valid_header(url) or url.contains(" ") or url.contains("\\"): return false
	var host := url.get_slice("/", 2)
	if host.is_empty() or host.contains("@"): return false
	if url.begins_with("https://"): return true
	return url.begins_with("http://") and host.get_slice(":", 0) in ["localhost", "127.0.0.1"]

static func _reply(operation: String, result: int, status: int, bytes: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS: return {"error": "Remote DataStore request failed (network result %d)" % result}
	if status < 200 or status >= 300: return {"error": "Remote DataStore returned HTTP %d" % status}
	var data = JSON.parse_string(bytes.get_string_from_utf8())
	if not data is Dictionary or not data.get("ok") is bool: return {"error": "Invalid remote DataStore response"}
	if not data.ok: return {"error": str(data.get("error", "Remote DataStore rejected the operation")).left(512)}
	if not data.has("result"): return {"error": "Remote DataStore response is missing its result"}
	var value = data.result
	match operation:
		"get", "remove":
			if value != null and (not value is Dictionary or not value.has("data") or not value.get("revision") is String or value.revision.is_empty()):
				return {"error": "Remote DataStore returned an invalid record"}
		"set", "compare_and_set":
			if not (value is String and not value.is_empty()) and not (operation == "compare_and_set" and value == false):
				return {"error": "Remote DataStore returned an invalid revision"}
		"increment":
			if not (value is int or value is float): return {"error": "Remote DataStore returned an invalid counter"}
	return {"value": value}
