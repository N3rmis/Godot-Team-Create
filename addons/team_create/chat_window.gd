@tool
extends Window

var network: Node

class DropTarget extends MarginContainer:
	var chat_window: Window

	func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
		if typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "files":
			for f in data["files"]:
				var ext = f.get_extension().to_lower()
				if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
					return true
		return false

	func _drop_data(at_position: Vector2, data: Variant) -> void:
		if typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "files":
			for f in data["files"]:
				var ext = f.get_extension().to_lower()
				if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
					chat_window._send_image(f)

var message_vbox: VBoxContainer
var pinned_vbox: VBoxContainer
var scroll_container: ScrollContainer
var input_edit: LineEdit
var send_btn: Button

var messages_data = [] # Array of dictionaries
var current_display_count = 20

func _init():
	title = "Team Chat"

	# Try to find a global network instance if possible or assign later
	size = Vector2(400, 500)
	min_size = Vector2(300, 300)
	visible = false
	exclusive = false
	close_requested.connect(hide)

	var drop_target = DropTarget.new()
	drop_target.chat_window = self
	drop_target.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	drop_target.add_theme_constant_override("margin_left", 8)
	drop_target.add_theme_constant_override("margin_right", 8)
	drop_target.add_theme_constant_override("margin_top", 8)
	drop_target.add_theme_constant_override("margin_bottom", 8)
	add_child(drop_target)

	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	drop_target.add_child(main_vbox)

	# Pinned messages container
	var pinned_scroll = ScrollContainer.new()
	pinned_scroll.custom_minimum_size = Vector2(0, 0)
	pinned_scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	pinned_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(pinned_scroll)

	pinned_vbox = VBoxContainer.new()
	pinned_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pinned_scroll.add_child(pinned_vbox)

	var sep1 = HSeparator.new()
	main_vbox.add_child(sep1)

	# Scroll container for chat
	scroll_container = ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(scroll_container)

	message_vbox = VBoxContainer.new()
	message_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	message_vbox.alignment = BoxContainer.ALIGNMENT_END
	scroll_container.add_child(message_vbox)

	# Detect scrolling to top
	scroll_container.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)

	var sep2 = HSeparator.new()
	main_vbox.add_child(sep2)

	# Input area
	var input_hbox = HBoxContainer.new()
	input_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(input_hbox)

	input_edit = LineEdit.new()
	input_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_edit.placeholder_text = "Type a message or drag & drop an image..."
	input_edit.text_submitted.connect(_on_input_submitted)
	input_hbox.add_child(input_edit)

	send_btn = Button.new()
	send_btn.text = "Send"
	send_btn.pressed.connect(_on_send_pressed)
	input_hbox.add_child(send_btn)

func _send_image(path: String):
	if network:
		network.send_chat_message("", path)

func _on_input_submitted(text: String):
	_on_send_pressed()

func _on_send_pressed():
	var text = input_edit.text.strip_edges()
	if text != "":
		if text == "/clearchat":
			if network:
				network.clear_chat()
		else:
			if network:
				network.send_chat_message(text, "")
		input_edit.text = ""

func _on_scroll_changed(value: float):
	if value <= 0 and current_display_count < messages_data.size():
		current_display_count += 20
		_refresh_messages(false)

func add_message(msg_data: Dictionary):
	messages_data.append(msg_data)
	_refresh_messages(true)

func set_messages(history: Array):
	messages_data = history
	current_display_count = 20
	_refresh_messages(true)

func _refresh_messages(scroll_to_bottom: bool = false):
	for c in message_vbox.get_children():
		c.queue_free()
	for c in pinned_vbox.get_children():
		c.queue_free()

	var start_idx = max(0, messages_data.size() - current_display_count)

	var pinned_msgs = []
	for m in messages_data:
		if m.get("pinned", false):
			pinned_msgs.append(m)

	for m in pinned_msgs:
		pinned_vbox.add_child(_create_message_node(m, true))

	for i in range(start_idx, messages_data.size()):
		message_vbox.add_child(_create_message_node(messages_data[i], false))

	if scroll_to_bottom:
		call_deferred("_scroll_to_bottom")

func _scroll_to_bottom():
	var scrollbar = scroll_container.get_v_scroll_bar()
	scrollbar.value = scrollbar.max_value

func _create_message_node(m: Dictionary, is_pinned: bool) -> Control:
	var type = m.get("type", "text")

	if type == "join":
		var lbl = Label.new()
		lbl.text = m.get("text", "User joined")
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 0.5))
		return lbl

	var hbox = HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var pin_btn = Button.new()
	pin_btn.text = "📌" if m.get("pinned", false) else "📍"
	pin_btn.flat = true
	pin_btn.tooltip_text = "Unpin" if m.get("pinned", false) else "Pin message"
	pin_btn.pressed.connect(func():
		if network:
			network.toggle_pin_message(m["id"])
	)
	hbox.add_child(pin_btn)

	var rtl = RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.selection_enabled = true

	var sender_name = m.get("sender_name", "Unknown")
	var color = m.get("sender_color", "ffffff")
	if color is Color:
		color = color.to_html(false)
	elif color is String and color.length() > 6:
		color = color.left(6) # ensure we just have RRGGBB if it was RRGGBBAA

	if type == "text":
		var text = m.get("text", "")
		# Sanitize basic tags to avoid malicious inputs breaking bbcode formatting
		text = text.replace("[", "[lb]")
		rtl.text = "[color=#" + color + "][b]" + sender_name + ":[/b][/color] " + text
	elif type == "image":
		var path = m.get("path", "")
		path = path.replace("[", "[lb]")
		rtl.text = "[color=#" + color + "][b]" + sender_name + ":[/b][/color]\n[img width=150]" + path + "[/img]"

	hbox.add_child(rtl)
	return hbox
