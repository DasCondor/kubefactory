extends SceneTree

const Agent = preload("res://scripts/agent.gd")
const LiveView = preload("res://scripts/liveview.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var live = LiveView.new()
	root.add_child(live)
	var session = live.open("http://127.0.0.1:18765/liveview_page.html", "Shutdown test")
	var deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (session["state"] == "opening" or (session["state"] == "live" and session["frames"] == 0)):
		await create_timer(0.1).timeout
	if session["state"] != "live" or session["frames"] == 0:
		printerr("LiveView did not start: ", session.get("msg", ""))
		live.queue_free()
		await process_frame
		await process_frame
		Agent.shutdown()
		quit(1)
		return
	var pid = Agent._pid
	live.queue_free()
	await process_frame
	await process_frame
	Agent.shutdown()
	if OS.is_process_running(pid):
		printerr("Companion still running after shutdown")
		quit(1)
		return
	print("LIVEVIEW SHUTDOWN PASSED")
	quit()
