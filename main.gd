# Role bootstrap. One project exports to two artifacts:
#   • headless server  (run with --headless, or --server)  -> server scene
#   • desktop client    (GUI, or a cryptocage:// launch URL) -> client scene
# Also handles one-shot --register-protocol / --unregister-protocol (Windows).
extends Node

const SERVER_SCENE := "res://server/main_server.tscn"
const CLIENT_SCENE := "res://client/main_client.tscn"


func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())

	if args.has("--register-protocol"):
		_register_protocol()
		get_tree().quit()
		return
	if args.has("--unregister-protocol"):
		_unregister_protocol()
		get_tree().quit()
		return

	var want_server := args.has("--server") or DisplayServer.get_name() == "headless"
	var want_client := args.has("--client") or _has_launch_url(args)
	var scene := SERVER_SCENE if (want_server and not want_client) else CLIENT_SCENE
	get_tree().change_scene_to_file.call_deferred(scene)


static func _has_launch_url(args: PackedStringArray) -> bool:
	for a in args:
		if a.begins_with("cryptocage://"):
			return true
	return false


# --- cryptocage:// protocol registration -------------------------------------
# Windows: per-user registry (no admin needed). macOS registers via the app
# bundle's Info.plist CFBundleURLTypes at build time; Linux via a .desktop file
# with MimeType=x-scheme-handler/cryptocage + xdg-mime default.
func _register_protocol() -> void:
	if OS.get_name() != "Windows":
		push_warning("Protocol auto-registration implemented for Windows only. On macOS use Info.plist CFBundleURLTypes; on Linux a .desktop x-scheme-handler/cryptocage entry.")
		return
	# Use a .reg import so the open-command keeps its quotes (an installed exe
	# path contains spaces, e.g. C:\Program Files\...). reg.exe /d strips quotes.
	var exe := OS.get_executable_path().replace("/", "\\")
	var exe_reg := exe.replace("\\", "\\\\") # .reg values escape backslashes
	# Produces: @="\"<exe>\" \"%1\""
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
	var out: Array = []
	OS.execute("reg", ["import", path.replace("/", "\\")], out, true)
	print("[cage] registered cryptocage:// -> %s" % exe)


func _unregister_protocol() -> void:
	if OS.get_name() != "Windows":
		return
	OS.execute("reg", ["delete", "HKCU\\Software\\Classes\\cryptocage", "/f"])
	print("[cage] unregistered cryptocage://")
