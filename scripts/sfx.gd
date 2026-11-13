extends Node
# Procedural sound effects: every sound is synthesised at startup, no audio files.

const RATE = 22050

static var streams = {}

var muted = false
var _pool = []
var _next = 0
var _charge: AudioStreamPlayer
var _hum: AudioStreamPlayer

# gen(t, dur) -> sample in -1..1
static func _make(dur: float, gen: Callable, loop: bool = false) -> AudioStreamWAV:
	var n = int(dur * RATE)
	var data = PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t = float(i) / RATE
		data.encode_s16(i * 2, int(clampf(gen.call(t, dur), -1.0, 1.0) * 30000.0))
	var s = AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_end = n
	return s

static func build_streams() -> void:
	if not streams.is_empty():
		return
	var rng = RandomNumberGenerator.new()
	rng.seed = 5
	# tool switch: short metallic tick
	streams["click"] = _make(0.07, func(t, d): return sin(TAU * 1400.0 * t) * exp(-t * 70.0) * 0.6 + rng.randf_range(-0.2, 0.2) * exp(-t * 120.0))
	# build: rising chirp ending in a thunk
	streams["build"] = _make(0.34, func(t, d): return sin(TAU * (220.0 + 900.0 * t) * t) * (1.0 - t / d) * 0.55 + sin(TAU * 70.0 * t) * exp(-maxf(t - 0.2, 0.0) * 30.0) * (0.7 if t > 0.2 else 0.0))
	# dismantle: falling buzz with grit
	streams["dismantle"] = _make(0.38, func(t, d): return (signf(sin(TAU * (520.0 - 900.0 * t) * t)) * 0.3 + rng.randf_range(-0.35, 0.35)) * (1.0 - t / d))
	# demolish: low boom
	streams["boom"] = _make(0.8, func(t, d): return (sin(TAU * (90.0 - 60.0 * t) * t) * 0.9 + rng.randf_range(-0.5, 0.5) * exp(-t * 9.0)) * exp(-t * 4.0))
	# confirmation: two rising blips
	streams["ok"] = _make(0.22, func(t, d): return sin(TAU * (660.0 if t < 0.1 else 990.0) * t) * exp(-fmod(t, 0.1) * 22.0) * 0.5)
	# failure: two low buzzes
	streams["error"] = _make(0.36, func(t, d): return signf(sin(TAU * 150.0 * t)) * (0.4 if fmod(t, 0.18) < 0.12 else 0.0))
	# datapad: soft whoosh + chirp
	streams["pad"] = _make(0.25, func(t, d): return rng.randf_range(-0.3, 0.3) * sin(PI * t / d) + sin(TAU * (500.0 + 1600.0 * t) * t) * 0.15 * sin(PI * t / d))
	# footstep: dull thump
	streams["step"] = _make(0.09, func(t, d): return (sin(TAU * 95.0 * t) * 0.8 + rng.randf_range(-0.25, 0.25)) * exp(-t * 55.0))
	# charging a hold action (looped, pitched up with progress)
	streams["charge"] = _make(0.2, func(t, d): return sin(TAU * 220.0 * t) * 0.35 + sin(TAU * 440.0 * t) * 0.15, true)
	# factory ambience (looped)
	streams["hum"] = _make(2.0, func(t, d): return sin(TAU * 55.0 * t) * 0.3 + sin(TAU * 110.5 * t) * 0.12 + sin(TAU * 82.0 * t) * 0.1 * sin(TAU * 0.5 * t), true)
	# alarm on failing machines (looped, positional)
	streams["alarm"] = _make(1.0, func(t, d): return sin(TAU * (700.0 if fmod(t, 0.5) < 0.25 else 520.0) * t) * (0.45 if fmod(t, 0.5) < 0.42 else 0.0), true)

func _ready() -> void:
	build_streams()
	for i in 8:
		var p = AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_charge = AudioStreamPlayer.new()
	_charge.stream = streams["charge"]
	_charge.volume_db = -16.0
	add_child(_charge)
	_hum = AudioStreamPlayer.new()
	_hum.stream = streams["hum"]
	_hum.volume_db = -24.0
	add_child(_hum)
	_hum.play()

func play(sound: String, volume_db: float = -10.0, pitch: float = 1.0) -> void:
	if muted or not streams.has(sound):
		return
	var p = _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = streams[sound]
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()

# progress 0..1 of a hold action; 0 stops the tone
func charge(progress: float) -> void:
	if progress <= 0.0 or muted:
		if _charge.playing:
			_charge.stop()
		return
	_charge.pitch_scale = 0.7 + progress * 1.6
	if not _charge.playing:
		_charge.play()

func set_muted(m: bool) -> void:
	muted = m
	AudioServer.set_bus_mute(0, m)
