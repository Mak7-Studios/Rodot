@tool
extends RefCounted

const URL := "rodot/datastores/supabase_url"
const EDITOR_KEY := "RODOT_EDITOR_SUPABASE_KEY"
const EDITOR_SCOPE := "RODOT_EDITOR_SUPABASE_SCOPE"
const SERVER_KEY := "RODOT_SUPABASE_SECRET_KEY"

static func origin(value: String) -> String:
	value = value.strip_edges().trim_suffix("/")
	if value.contains("\r") or value.contains("\n") or value.contains(" ") or value.contains("\\") or value.contains("?") or value.contains("#"):
		return ""
	if value.get_slice_count("/") != 3: return ""
	var host := value.get_slice("/", 2)
	if host.is_empty() or host.contains("@"): return ""
	if value.begins_with("https://") or (value.begins_with("http://") and host.get_slice(":", 0) in ["localhost", "127.0.0.1"]):
		return value.to_lower()
	return ""

static func scope(base: String) -> String:
	var root := ProjectSettings.globalize_path("res://").replace("\\", "/").simplify_path().trim_suffix("/")
	if OS.get_name() == "Windows": root = root.to_lower()
	return JSON.stringify([root, base]).sha256_text()

static func valid_key(key: String) -> bool:
	if key.length() > 2048: return false
	for character in key:
		if character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-": return false
	if key.begins_with("sb_secret_"): return key.length() > "sb_secret_".length()
	return key.begins_with("eyJ") and key.get_slice_count(".") == 3

static func key_for(base: String) -> String:
	var editor_scope := OS.get_environment(EDITOR_SCOPE)
	if not editor_scope.is_empty():
		return OS.get_environment(EDITOR_KEY) if editor_scope == scope(base) else ""
	return OS.get_environment(SERVER_KEY).strip_edges()
