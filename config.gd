# Config — project-wide configuration autoload (singleton "Config").
#
# Centralizes every tunable the server and client read. Exported vars give
# editable defaults in the Inspector; at runtime they are overridden (in order of
# precedence) by a matching CLI arg, then an environment variable, else the
# exported default. This keeps the Hetzner host, URLs and engine version out of
# code while never baking secrets into the committed project.
#
# SECURITY: SERVER_SETTLE_TOKEN is intentionally NOT an exported var — it is
# resolved from the environment only, so a real token can never be committed via
# the Inspector/scene. Leave it empty in the project; provide it via the service
# environment (see BUILD.md / the systemd EnvironmentFile).
extends Node

# --- Shared / server ----------------------------------------------------------
## FNV-1a (8 hex) of the published base44/shared/fightSim.js. Pin per release
## (GET /functions/get-engine-source). Empty until pinned — do not guess.
@export var engine_version: String = ""
## ENet UDP + WebSocket TCP port.
@export var port: int = 7777
## Base44 settlement endpoint (server-only POST).
@export var settle_url: String = "https://cryptocage.base44.app/functions/settle-native-match"
## WebSocket TCP fallback alongside ENet.
@export var ws_enabled: bool = true
## Cosmetic 3-2-1-FIGHT lead-in before the bout goes LIVE (ticks).
@export var countdown_ticks: int = 180
## Round length cap in ticks (clamped to the replay codec max, 6000, by MatchRoom).
@export var match_ticks: int = 6000

# --- Client -------------------------------------------------------------------
## Base44 seat verification endpoint (public to the native client).
@export var verify_url: String = "https://cryptocage.base44.app/functions/verify-match-seat"
## Where the client returns the player after a bout ends.
@export var web_url: String = "https://cryptocage.base44.app"

# --- Secret (env only; never exported/committed) ------------------------------
var settle_token: String = ""

var _args: PackedStringArray


func _ready() -> void:
	_args = OS.get_cmdline_args()
	_args.append_array(OS.get_cmdline_user_args())
	engine_version = _str(engine_version, "CAGE_ENGINE_VERSION", "--engine-version=")
	port = _int(port, "CAGE_PORT", "--cage-port=")
	settle_url = _str(settle_url, "CAGE_SETTLE_URL", "--settle-url=")
	countdown_ticks = _int(countdown_ticks, "CAGE_COUNTDOWN_TICKS", "--countdown-ticks=")
	match_ticks = _int(match_ticks, "CAGE_MATCH_TICKS", "--match-ticks=")
	verify_url = _str(verify_url, "CAGE_VERIFY_URL", "--verify-url=")
	web_url = _str(web_url, "CAGE_WEB_URL", "--web-url=")
	ws_enabled = _resolve_ws(ws_enabled)
	# Secret: environment only.
	if OS.has_environment("SERVER_SETTLE_TOKEN"):
		settle_token = OS.get_environment("SERVER_SETTLE_TOKEN")


func _has_cli(prefix: String) -> bool:
	if prefix == "":
		return false
	for a in _args:
		if a.begins_with(prefix):
			return true
	return false


func _cli(prefix: String) -> String:
	for a in _args:
		if prefix != "" and a.begins_with(prefix):
			return a.split("=", true, 1)[1]
	return ""


func _str(def: String, env_key: String, cli_prefix: String) -> String:
	if _has_cli(cli_prefix):
		return _cli(cli_prefix)
	if env_key != "" and OS.has_environment(env_key) and OS.get_environment(env_key) != "":
		return OS.get_environment(env_key)
	return def


func _int(def: int, env_key: String, cli_prefix: String) -> int:
	var s := _str(str(def), env_key, cli_prefix)
	return int(s) if s.is_valid_int() else def


func _resolve_ws(def: bool) -> bool:
	if _args.has("--no-ws"):
		return false
	if OS.has_environment("CAGE_WS") and OS.get_environment("CAGE_WS") == "0":
		return false
	return def


# --- cryptocage:// protocol handler ------------------------------------------
# Kept here (in the always-alive autoload) so both the --register-protocol flag
# and the client's self-registration can reach it after scene changes.
func ensure_protocol_registered() -> void:
	# Register on launch when the stored handler path differs from this exe
	# (first run, or the binary moved). Idempotent and cheap.
	if OS.get_name() != "Windows":
		return
	if OS.has_feature("editor"):
		return # only an exported client self-registers; dev/editor runs stay clean
	var exe := OS.get_executable_path()
	var marker := "user://cryptocage_protocol.txt"
	var stored := ""
	if FileAccess.file_exists(marker):
		var rf := FileAccess.open(marker, FileAccess.READ)
		if rf != null:
			stored = rf.get_as_text().strip_edges()
			rf.close()
	if stored == exe:
		return
	register_protocol()
	var wf := FileAccess.open(marker, FileAccess.WRITE)
	if wf != null:
		wf.store_string(exe)
		wf.close()


func register_protocol() -> void:
	if OS.get_name() != "Windows":
		push_warning("Protocol auto-registration is Windows-only. macOS: Info.plist CFBundleURLTypes; Linux: a .desktop x-scheme-handler/cryptocage entry.")
		return
	var exe := OS.get_executable_path().replace("/", "\\")
	var exe_reg := exe.replace("\\", "\\\\")
	var cmd_line := '@="' + '\\"' + exe_reg + '\\"' + ' ' + '\\"%1\\"' + '"'
	var content := "Windows Registry Editor Version 5.00\r\n\r\n" \
		+ "[HKEY_CURRENT_USER\\Software\\Classes\\cryptocage]\r\n" \
		+ '@="URL:Crypto Cage Combat"\r\n' \
		+ '"URL Protocol"=""\r\n\r\n' \
		+ "[HKEY_CURRENT_USER\\Software\\Classes\\cryptocage\\shell\\open\\command]\r\n" \
		+ cmd_line + "\r\n"
	var path := OS.get_cache_dir().path_join("cryptocage_register.reg")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[cage] could not write .reg file to %s" % path)
		return
	f.store_string(content)
	f.close()
	OS.execute("reg", ["import", path.replace("/", "\\")], [], true)
	print("[cage] registered cryptocage:// -> %s" % exe)


func unregister_protocol() -> void:
	if OS.get_name() != "Windows":
		return
	OS.execute("reg", ["delete", "HKCU\\Software\\Classes\\cryptocage", "/f"], [], true)
	var marker := "user://cryptocage_protocol.txt"
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(marker))
	print("[cage] unregistered cryptocage://")
