@tool
extends RefCounted

const ROOT := "res://addons/rodot/roblox_content/"
const ONLINE_SETTING := "rodot/experimental/online_asset_ids"
const ID_SCHEMES := ["rbxassetid", "rodotassetid", "roassetid"]
const PATH_SCHEMES := ["rodotasset", "rbxasset"]
const PUBLIC_API := "https://assetdelivery.roblox.com/v2/assetId/"
const CLOUD_API := "https://apis.roblox.com/asset-delivery-api/v1/assetId/"
const MAX_IMAGE_BYTES := 16 * 1024 * 1024

var _request: HTTPRequest

static func _id_digits(value: String) -> String:
	if value.is_empty() or value.length() > 20: return ""
	for character in value:
		if character < "0" or character > "9": return ""
	while value.begins_with("0"): value = value.substr(1)
	return value

static func asset_id(path: String) -> String:
	var parts := path.split("://", true, 1)
	if parts.size() != 2 or parts[0] not in ID_SCHEMES + PATH_SCHEMES: return ""
	return _id_digits(parts[1])

static func accepts_texture(path: String) -> bool:
	return path.is_empty() or not asset_id(path).is_empty() or texture(path) != null

static func texture(path: String) -> Texture2D:
	if path.is_empty(): return null
	if not asset_id(path).is_empty(): return null
	if path.begins_with("rodotasset://") or path.begins_with("rbxasset://"):
		var relative := path.get_slice("://", 1).replace("\\", "/").simplify_path()
		if relative.begins_with("../") or relative == ".." or relative.is_absolute_path(): return null
		path = ROOT + relative
	if not path.begins_with("res://"): return null
	path = path.simplify_path()
	if path.begins_with(ROOT):
		if not FileAccess.file_exists(path): return null
		return _decode_image(FileAccess.get_file_as_bytes(path), path.get_extension().to_lower())
	if ResourceLoader.exists(path, "Texture2D"): return load(path) as Texture2D
	return null

static func _decode_image(bytes: PackedByteArray, format: String, dimension_limit := 0) -> Texture2D:
	var image := Image.new()
	var result := ERR_FILE_UNRECOGNIZED
	match format:
		"png": result = image.load_png_from_buffer(bytes)
		"jpg", "jpeg": result = image.load_jpg_from_buffer(bytes)
		"webp": result = image.load_webp_from_buffer(bytes)
		"dds": result = image.load_dds_from_buffer(bytes)
		"svg": result = image.load_svg_from_buffer(bytes)
	if result != OK or image.is_empty(): return null
	if dimension_limit > 0 and maxi(image.get_width(), image.get_height()) > dimension_limit: return null
	return ImageTexture.create_from_image(image)

func cancel() -> void:
	if is_instance_valid(_request):
		_request.cancel_request()
		_request.queue_free()
	_request = null

func load_into(owner: Node, path: String, apply: Callable) -> void:
	cancel()
	var id := asset_id(path)
	if id.is_empty():
		var image := texture(path)
		apply.call(image, "Texture could not be loaded: " + path if image == null and not path.is_empty() else "")
		return
	if not ProjectSettings.get_setting(ONLINE_SETTING, false):
		apply.call(null, "Enable Rodot > Experimental > Online Asset IDs to load " + path)
		return
	var request := HTTPRequest.new()
	request.timeout = 10.0
	request.body_size_limit = MAX_IMAGE_BYTES
	request.max_redirects = 0
	request.process_mode = Node.PROCESS_MODE_ALWAYS
	owner.add_child(request, false, Node.INTERNAL_MODE_FRONT)
	_request = request
	apply.call(null, "")
	_download.call_deferred(request, id, apply)

func _download(request: HTTPRequest, id: String, apply: Callable) -> void:
	if not is_instance_valid(request) or request != _request or not request.is_inside_tree(): return
	var key := OS.get_environment("RODOT_ROBLOX_API_KEY").strip_edges()
	var result := await _fetch(request, id, key)
	if not is_instance_valid(request) or request != _request: return
	_request = null
	request.queue_free()
	if apply.is_valid(): apply.call(result.get("texture"), result.get("error", ""))

static func _is_delivery_url(url: String) -> bool:
	if not url.begins_with("https://") or url.contains("\r") or url.contains("\n"): return false
	var host := url.get_slice("/", 2).to_lower()
	for character in host:
		if character not in "abcdefghijklmnopqrstuvwxyz0123456789.-": return false
	return host in ["apis.roblox.com", "assetdelivery.roblox.com", "rbxcdn.com"] or host.ends_with(".rbxcdn.com")

static func _location(headers: PackedStringArray, url: String) -> String:
	for header in headers:
		if not header.to_lower().begins_with("location:"): continue
		var target := header.substr(9).strip_edges()
		if target.begins_with("/") and not target.begins_with("//"):
			return "https://" + url.get_slice("/", 2) + target
		return target
	return ""

static func _delivery_location(body: PackedByteArray) -> String:
	if body.size() > 65536: return ""
	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json is Dictionary: return ""
	var direct = json.get("location", "")
	if direct is String and not direct.is_empty(): return direct
	var locations = json.get("locations", [])
	if locations is Array:
		for entry in locations:
			if entry is Dictionary and entry.get("location") is String: return entry.location
	return ""

static func _decal_texture_id(body: PackedByteArray) -> String:
	if body.size() > 262144: return ""
	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK: return ""
	var in_texture := false
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and parser.get_node_name() == "Content":
			in_texture = parser.get_named_attribute_value_safe("name") in ["Texture", "ColorMapContent"]
		elif parser.get_node_type() == XMLParser.NODE_ELEMENT_END and parser.get_node_name() == "Content":
			in_texture = false
		elif in_texture and parser.get_node_type() == XMLParser.NODE_TEXT:
			var value := parser.get_node_data().strip_edges()
			var id := asset_id(value)
			if not id.is_empty(): return id
			for prefix in ["http://www.roblox.com/asset/?id=", "https://www.roblox.com/asset/?id="]:
				if value.begins_with(prefix): return _id_digits(value.trim_prefix(prefix).get_slice("&", 0))
	return ""

static func _image_format(body: PackedByteArray) -> String:
	if body.size() >= 4:
		if body[0] == 137 and body.slice(1, 4).get_string_from_ascii() == "PNG": return "png"
		if body[0] == 255 and body[1] == 216 and body[2] == 255: return "jpg"
		if body.slice(0, 4).get_string_from_ascii() == "DDS ": return "dds"
	if body.size() >= 12 and body.slice(8, 12).get_string_from_ascii() == "WEBP": return "webp"
	return ""

static func _fetch(request: HTTPRequest, id: String, key: String) -> Dictionary:
	if key.contains("\r") or key.contains("\n"): return {"error": "RODOT_ROBLOX_API_KEY contains a line break."}
	var endpoint := PUBLIC_API if key.is_empty() else CLOUD_API
	var delivery_url := endpoint + id
	var url := delivery_url
	var followed_decal := false
	for attempt in range(6):
		if not _is_delivery_url(url): return {"error": "Asset delivery returned an unsupported download address."}
		var headers := PackedStringArray()
		if not key.is_empty() and url == delivery_url: headers.append("x-api-key: " + key)
		var error := request.request(url, headers)
		if error != OK: return {"error": "Could not start the Roblox asset request (%s)." % error_string(error)}
		var response: Array = await request.request_completed
		var status: int = response[1]
		if status in [301, 302, 303, 307, 308]:
			url = _location(response[2], url)
			continue
		if response[0] != HTTPRequest.RESULT_SUCCESS:
			return {"error": "Roblox asset request failed (network result %s)." % response[0]}
		if status in [401, 403]:
			var hint := " Set RODOT_ROBLOX_API_KEY for assets your account can access." if key.is_empty() else " Check the key's asset access."
			return {"error": "Roblox denied access to asset %s (HTTP %d)." % [id, status] + hint}
		if status != 200: return {"error": "Roblox asset %s returned HTTP %d." % [id, status]}
		var body: PackedByteArray = response[3]
		var format := _image_format(body)
		if not format.is_empty():
			var image := _decode_image(body, format, 4096)
			if image != null: return {"texture": image}
			return {"error": "Roblox returned an invalid or oversized texture for asset " + id}
		var prefix := body.slice(0, mini(body.size(), 128)).get_string_from_ascii().strip_edges()
		if prefix.begins_with("{"):
			url = _delivery_location(body)
			if not url.is_empty(): continue
			return {"error": "Roblox did not provide a download for asset " + id}
		if prefix.begins_with("<") and not followed_decal:
			var image_id := _decal_texture_id(body)
			if not image_id.is_empty() and image_id != id:
				followed_decal = true
				delivery_url = endpoint + image_id
				url = delivery_url
				continue
		return {"error": "Roblox asset %s did not contain a supported image. Try its texture ID." % id}
	return {"error": "Roblox asset delivery exceeded the redirect limit."}
