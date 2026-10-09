# Crypto Cage Combat — desktop client (rendering + local input).
#
# Parses the cryptocage:// launch URL, verifies the seat with Base44, connects to
# the authoritative server, sends ONLY per-tick inputs, and renders the server's
# authoritative snapshots. On ENDED it shows the result and returns to the web app.
extends Node2D

const DEFAULT_VERIFY_URL := "https://cryptocage.base44.app/functions/verify-match-seat"
const DEFAULT_WEB_URL := "https://cryptocage.base44.app"
const NetClientScript = preload("res://client/net_client.gd")

# Stage/world -> screen layout.
const MARGIN := 80.0
const GROUND_Y := 440.0
const Y_SCALE := 3.2
const FIGHTER_W := 34.0
const FIGHTER_H := 96.0

var _nc: NetClientScript
var _status := "Launching…"
var _ended_info: Dictionary = {}
var _exit_countdown := -1.0
var _verify_url := DEFAULT_VERIFY_URL
var _web_url := DEFAULT_WEB_URL
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_verify_url = Config.verify_url
	_web_url = Config.web_url
	_wire_window()
	# An exported client self-registers cryptocage:// on launch (no-op in editor).
	Config.ensure_protocol_registered()

	_nc = NetClientScript.new()
	add_child(_nc)
	_nc.verified.connect(func(ctx): _status = "Connecting to %s (seat %d)…" % [ctx.get("server_url"), ctx.get("seat")])
	_nc.server_connected.connect(func(): _status = "Connected — waiting for opponent…")
	_nc.state_received.connect(func(_s): pass)
	_nc.match_ended.connect(_on_ended)
	_nc.rejected.connect(func(r): _status = "Match refused: %s" % r)
	_nc.verify_failed.connect(func(code, msg): _status = "Verify failed (%s): %s" % [code, msg]; _begin_exit(8.0))
	_nc.disconnected.connect(func(): _status = "Disconnected from server.")

	var token := _launch_token()
	var direct_server := _cfg("", "--server-url=", "") # dev: skip verify, connect directly
	if direct_server != "":
		_nc.context = {
			"match_id": _cfg("", "--match=", "dev"), "seat": int(_cfg("", "--seat=", "1")),
			"engine_version": _cfg("CAGE_ENGINE_VERSION", "--engine-version=", ""),
			"server_url": direct_server,
			"fighter_id": _cfg("", "--fighter=", "f1"), "opponent_fighter_id": _cfg("", "--opponent=", "f2"),
		}
		_status = "Connecting (dev) to %s…" % direct_server
		_nc.call_deferred("_connect_to_server")
	elif token != "":
		_status = "Verifying seat…"
		_nc.start_from_token(token, _verify_url)
	else:
		_status = "No cryptocage:// launch URL. Open a match from the web app."


func _wire_window() -> void:
	var win := get_window()
	if win == null:
		return
	win.title = "Crypto Cage Combat"
	win.min_size = Vector2i(640, 360)
	# Clean up the net connection on window close before quitting.
	if not win.close_requested.is_connected(_on_close_requested):
		win.close_requested.connect(_on_close_requested)


func _on_close_requested() -> void:
	if _nc != null:
		_nc.close()
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()


func _process(delta: float) -> void:
	if _nc != null and _ended_info.is_empty():
		_nc.set_input(_read_input())
		_nc.poll()
	if _exit_countdown >= 0.0:
		_exit_countdown -= delta
		if _exit_countdown <= 0.0:
			_exit_countdown = -1.0
			if _web_url != "":
				OS.shell_open(_web_url)
			get_tree().quit()
	queue_redraw()


func _read_input() -> Dictionary:
	var md := 0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		md -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		md += 1
	var jump := Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_SPACE)
	var crouch := Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)
	var action := ""
	if Input.is_physical_key_pressed(KEY_L):
		action = "special"
	elif Input.is_physical_key_pressed(KEY_K):
		action = "heavy"
	elif Input.is_physical_key_pressed(KEY_J):
		action = "light"
	return {"moveDir": md, "jump": jump, "crouch": crouch, "action": action}


func _on_ended(info: Dictionary) -> void:
	_ended_info = info
	var me: int = _nc.context.get("seat", 0)
	var w: int = int(info.get("winner_seat", 0))
	if w == 0:
		_status = "DRAW"
	elif w == me:
		_status = "YOU WIN"
	else:
		_status = "YOU LOSE"
	_begin_exit(8.0)


func _begin_exit(secs: float) -> void:
	if _exit_countdown < 0.0:
		_exit_countdown = secs


# --- Launch URL / config ------------------------------------------------------
func _launch_token() -> String:
	# The OS passes the cryptocage:// URL as a command-line argument.
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for a in args:
		if a.begins_with("cryptocage://"):
			return _token_from_url(a)
		if a.begins_with("--token="):
			return a.split("=", true, 1)[1]
	return ""


static func _token_from_url(url: String) -> String:
	# cryptocage://launch?match=<id>&seat=<1|2>&token=<jwt>
	var q := url.get_slice("?", 1)
	for pair in q.split("&"):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "token":
			return kv[1].uri_decode()
	return ""


func _cfg(env_key: String, cli_prefix: String, fallback: String) -> String:
	if cli_prefix != "":
		var args := OS.get_cmdline_args()
		args.append_array(OS.get_cmdline_user_args())
		for a in args:
			if a.begins_with(cli_prefix):
				return a.split("=", true, 1)[1]
	if env_key != "" and OS.has_environment(env_key):
		var v := OS.get_environment(env_key)
		if v != "":
			return v
	return fallback


# --- Rendering (authoritative snapshots only) ---------------------------------
func _world_to_screen_x(x: float) -> float:
	var w := float(get_viewport_rect().size.x)
	return MARGIN + (x - 8.0) / (92.0 - 8.0) * (w - 2.0 * MARGIN)


func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.07, 0.08, 0.11))
	draw_line(Vector2(0, GROUND_Y), Vector2(vp.x, GROUND_Y), Color(0.25, 0.27, 0.33), 2.0)

	var st := _nc.last_state if _nc != null else {}
	if st.has("p1") and st.has("p2"):
		_draw_fighter(st["p1"], Color(0.38, 0.64, 1.0), true)
		_draw_fighter(st["p2"], Color(1.0, 0.45, 0.42), false)
		for p in st.get("projectiles", []):
			var px := _world_to_screen_x(p.get("x", 0.0))
			var py := GROUND_Y - float(p.get("y", 0.0)) * Y_SCALE - 36.0
			draw_circle(Vector2(px, py), 9.0, Color(1.0, 0.85, 0.2))
		var combo := int(st.get("comboCount", 0))
		if combo > 1:
			_text(Vector2(vp.x / 2.0 - 40, 120), "%d HITS" % combo, 28, Color(1, 0.9, 0.3))

	# HUD
	_text(Vector2(20, 28), _status, 22, Color(0.9, 0.92, 0.96))
	var me: int = _nc.context.get("seat", 0) if _nc != null else 0
	if me != 0:
		_text(Vector2(20, 54), "You are seat %d  (A/D move · W jump · S crouch · J/K/L light/heavy/special)" % me, 15, Color(0.6, 0.63, 0.7))
	if not _ended_info.is_empty():
		var big := _status
		_text(Vector2(vp.x / 2.0 - big.length() * 11, vp.y / 2.0 - 30), big, 44, Color(1, 1, 1))
		_text(Vector2(vp.x / 2.0 - 110, vp.y / 2.0 + 20), "returning to the web app…", 16, Color(0.7, 0.72, 0.8))


func _draw_fighter(p: Dictionary, col: Color, left_side: bool) -> void:
	var x := _world_to_screen_x(float(p.get("x", 50.0)))
	var y := GROUND_Y - float(p.get("y", 0.0)) * Y_SCALE
	var crouching := bool(p.get("crouch", false))
	var h := FIGHTER_H * (0.6 if crouching else 1.0)
	var body := Rect2(x - FIGHTER_W / 2.0, y - h, FIGHTER_W, h)
	var c := col
	if float(p.get("flash", 0.0)) > 0.05:
		c = c.lerp(Color.WHITE, 0.6)
	if bool(p.get("ko", false)):
		c = c.darkened(0.4)
	draw_rect(body, c)
	# facing tick
	var fx: float = x + (FIGHTER_W / 2.0) * signf(float(p.get("facing", 1.0)))
	draw_line(Vector2(x, y - h * 0.7), Vector2(fx, y - h * 0.7), Color.WHITE, 3.0)
	# health + energy bars
	var hp := clampf(float(p.get("health", 0.0)) / 100.0, 0.0, 1.0)
	var en := clampf(float(p.get("energy", 0.0)) / 100.0, 0.0, 1.0)
	var bw := 360.0
	var bx := 30.0 if left_side else get_viewport_rect().size.x - 30.0 - bw
	draw_rect(Rect2(bx, 78, bw, 18), Color(0.2, 0.2, 0.24))
	draw_rect(Rect2(bx, 78, bw * hp, 18), col)
	draw_rect(Rect2(bx, 100, bw, 8), Color(0.2, 0.2, 0.24))
	draw_rect(Rect2(bx, 100, bw * en, 8), Color(1.0, 0.82, 0.25))


func _text(pos: Vector2, s: String, size: int, col: Color) -> void:
	if _font != null:
		draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
