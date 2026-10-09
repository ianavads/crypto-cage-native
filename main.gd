# Role bootstrap. One project exports to two artifacts:
#   • headless server  (run with --headless, or --server)  -> server scene
#   • desktop client    (GUI, or a cryptocage:// launch URL) -> client scene
# Also handles one-shot --register-protocol / --unregister-protocol (delegated to
# the Config autoload so the handler logic lives in one place).
extends Node

const SERVER_SCENE := "res://server/main_server.tscn"
const CLIENT_SCENE := "res://client/main_client.tscn"


func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())

	if args.has("--register-protocol"):
		Config.register_protocol()
		get_tree().quit()
		return
	if args.has("--unregister-protocol"):
		Config.unregister_protocol()
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
