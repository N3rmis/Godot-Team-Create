@tool
extends VBoxContainer

var network: Node

class DropTarget extends MarginContainer:
	var chat_window: VBoxContainer

	func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
		if typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "files":
			for f in data["files"]:
				var ext = str(f).get_extension().to_lower()
				if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
					return true
		elif typeof(data) == TYPE_ARRAY or typeof(data) == TYPE_PACKED_STRING_ARRAY:
			for f in data:
				if typeof(f) == TYPE_STRING:
					var ext = str(f).get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
						return true
		return false

	func _drop_data(at_position: Vector2, data: Variant) -> void:
		if typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "files":
			for f in data["files"]:
				var ext = str(f).get_extension().to_lower()
				if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
					chat_window._send_image(str(f))
		elif typeof(data) == TYPE_ARRAY or typeof(data) == TYPE_PACKED_STRING_ARRAY:
			for f in data:
				if typeof(f) == TYPE_STRING:
					var ext = str(f).get_extension().to_lower()
					if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
						chat_window._send_image(str(f))

# Virtualization constants
const MAX_RENDERED: int = 40
const BATCH_SIZE: int = 20
const PREFETCH_MARGIN: float = 200.0

var message_vbox: VBoxContainer
var scroll_container: ScrollContainer
var input_edit: LineEdit
var send_btn: Button
var attach_btn: Button
var jump_to_bottom_btn: Button
var pinned_btn: Button
var pinned_dialog: AcceptDialog
var pinned_list_vbox: VBoxContainer

var messages_data = [] # Complete history of message dictionaries
var rendered_start_idx: int = 0
var rendered_end_idx: int = 0
var _is_updating_scroll: bool = false
var _chat_texture_cache: Dictionary = {}

func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		var win = get_window()
		if win and not win.files_dropped.is_connected(_on_window_files_dropped):
			win.files_dropped.connect(_on_window_files_dropped)
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		if is_visible_in_tree():
			call_deferred("_scroll_to_bottom")

func _on_window_files_dropped(files: PackedStringArray) -> void:
	if not is_visible_in_tree():
		return
	var mouse_pos = get_global_mouse_position()
	if get_global_rect().has_point(mouse_pos):
		for f in files:
			var ext = f.get_extension().to_lower()
			if ext in ["png", "jpg", "jpeg", "webp", "svg", "bmp"]:
				_send_image(f)

func _init():
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var drop_target = DropTarget.new()
	drop_target.chat_window = self
	drop_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drop_target.size_flags_vertical = Control.SIZE_EXPAND_FILL
	drop_target.add_theme_constant_override("margin_left", 8)
	drop_target.add_theme_constant_override("margin_right", 8)
	drop_target.add_theme_constant_override("margin_top", 6)
	drop_target.add_theme_constant_override("margin_bottom", 6)
	add_child(drop_target)

	var main_vbox = VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	drop_target.add_child(main_vbox)

	# Top header bar with title and Pinned Messages button
	var top_bar = HBoxContainer.new()
	top_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(top_bar)

	var title_lbl = Label.new()
	title_lbl.text = "💬 Team Chat"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.8))
	top_bar.add_child(title_lbl)

	pinned_btn = Button.new()
	pinned_btn.text = "📌 Pinned (0)"
	pinned_btn.tooltip_text = "View pinned messages"
	pinned_btn.flat = true
	pinned_btn.pressed.connect(_on_pinned_btn_pressed)
	top_bar.add_child(pinned_btn)

	# Scroll container for chat messages
	var scroll_overlay = MarginContainer.new()
	scroll_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_overlay.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(scroll_overlay)

	scroll_container = ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll_overlay.add_child(scroll_container)

	jump_to_bottom_btn = Button.new()
	jump_to_bottom_btn.text = "V"
	jump_to_bottom_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	jump_to_bottom_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	jump_to_bottom_btn.pressed.connect(_on_jump_to_bottom_pressed)
	jump_to_bottom_btn.hide()
	scroll_overlay.add_child(jump_to_bottom_btn)

	message_vbox = VBoxContainer.new()
	message_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	message_vbox.alignment = BoxContainer.ALIGNMENT_END
	scroll_container.add_child(message_vbox)

	# Detect scrolling
	scroll_container.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)

	var sep = HSeparator.new()
	main_vbox.add_child(sep)

	# Input area
	var input_hbox = HBoxContainer.new()
	input_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(input_hbox)

	attach_btn = Button.new()
	attach_btn.text = "📷"
	attach_btn.tooltip_text = "Attach & send image file"
	attach_btn.pressed.connect(_on_attach_pressed)
	input_hbox.add_child(attach_btn)

	input_edit = LineEdit.new()
	input_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_edit.placeholder_text = "Type a message or drag & drop an image..."
	input_edit.text_submitted.connect(_on_input_submitted)
	input_hbox.add_child(input_edit)

	send_btn = Button.new()
	send_btn.text = "Send"
	send_btn.pressed.connect(_on_send_pressed)
	input_hbox.add_child(send_btn)

	# Separate Pinned Messages Dialog
	pinned_dialog = AcceptDialog.new()
	pinned_dialog.title = "📌 Pinned Messages"
	pinned_dialog.ok_button_text = "Close"
	pinned_dialog.dialog_hide_on_ok = true

	var pd_margin = MarginContainer.new()
	pd_margin.custom_minimum_size = Vector2(440, 280)
	pd_margin.add_theme_constant_override("margin_left", 8)
	pd_margin.add_theme_constant_override("margin_right", 8)
	pd_margin.add_theme_constant_override("margin_top", 8)
	pd_margin.add_theme_constant_override("margin_bottom", 8)

	var pd_scroll = ScrollContainer.new()
	pd_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pd_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pd_margin.add_child(pd_scroll)

	pinned_list_vbox = VBoxContainer.new()
	pinned_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pinned_list_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pd_scroll.add_child(pinned_list_vbox)

	pinned_dialog.add_child(pd_margin)
	add_child(pinned_dialog)

func _on_pinned_btn_pressed() -> void:
	_refresh_pinned_dialog()
	pinned_dialog.popup_centered(Vector2i(480, 320))

func _refresh_pinned_dialog() -> void:
	if not pinned_list_vbox:
		return
	for c in pinned_list_vbox.get_children():
		c.queue_free()

	var pinned_msgs = []
	for m in messages_data:
		if m.get("pinned", false):
			pinned_msgs.append(m)

	if pinned_msgs.is_empty():
		var empty_lbl = Label.new()
		empty_lbl.text = "No pinned messages yet."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		pinned_list_vbox.add_child(empty_lbl)
		return

	for m in pinned_msgs:
		var node = _create_message_node(m, true)
		pinned_list_vbox.add_child(node)

func _update_pinned_count() -> void:
	var count = 0
	for m in messages_data:
		if m.get("pinned", false):
			count += 1
	if pinned_btn:
		pinned_btn.text = "📌 Pinned (%d)" % count
	if pinned_dialog and pinned_dialog.visible:
		_refresh_pinned_dialog()

func _on_attach_pressed() -> void:
	if network and ("chat_images_enabled" in network) and not network.chat_images_enabled:
		if network.has_method("tc_print_rich"):
			network.tc_print_rich("[color=orange]Chat images are currently disabled on this server. Use /chatimgs true to enable.[/color]")
		elif network.has_method("tc_print"):
			network.tc_print("Chat images are currently disabled on this server. Use /chatimgs true to enable.")
		return

	var fd = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp, *.svg, *.bmp ; Image Files"])
	fd.file_selected.connect(func(path: String):
		_send_image(path)
		fd.queue_free()
	)
	fd.canceled.connect(func():
		fd.queue_free()
	)
	add_child(fd)
	fd.popup_centered_ratio(0.7)

func _send_image(path: String):
	if network:
		if ("chat_images_enabled" in network) and not network.chat_images_enabled:
			if network.has_method("tc_print_rich"):
				network.tc_print_rich("[color=orange]Chat images are currently disabled on this server. Use /chatimgs true to enable.[/color]")
			elif network.has_method("tc_print"):
				network.tc_print("Chat images are currently disabled on this server. Use /chatimgs true to enable.")
			return
		network.send_chat_message("", path)

func _on_input_submitted(text: String):
	_on_send_pressed()

func _on_send_pressed():
	var text = input_edit.text.strip_edges()
	if text != "":
		if text.begins_with("/"):
			var echo_msg = {
				"id": -1,
				"type": "command_echo",
				"text": text
			}
			add_message(echo_msg)
			if network and network.has_method("execute_chat_command"):
				network.execute_chat_command(text)
		else:
			if network:
				network.send_chat_message(text, "")
		input_edit.text = ""

func add_command_response(response_bbcode: String):
	var msg = {
		"id": -1,
		"type": "command_response",
		"text": response_bbcode
	}
	add_message(msg)

func _on_jump_to_bottom_pressed():
	jump_to_bottom_btn.text = "V"
	jump_to_bottom_btn.hide()
	if rendered_end_idx < messages_data.size():
		_rebuild_rendered_messages(true)
	else:
		call_deferred("_scroll_to_bottom")

func _on_scroll_changed(value: float):
	if _is_updating_scroll:
		return

	var scrollbar = scroll_container.get_v_scroll_bar()
	var at_bottom = value >= (scrollbar.max_value - scrollbar.page - 25.0)
	if at_bottom and rendered_end_idx >= messages_data.size():
		jump_to_bottom_btn.text = "V"
		jump_to_bottom_btn.hide()
	else:
		jump_to_bottom_btn.show()

	# Scroll near top: prefetch older messages
	if value <= PREFETCH_MARGIN and rendered_start_idx > 0:
		_load_older_messages()

	# Scroll near bottom: prefetch newer messages
	elif value >= (scrollbar.max_value - scrollbar.page - PREFETCH_MARGIN) and rendered_end_idx < messages_data.size():
		_load_newer_messages(at_bottom)

func _load_older_messages():
	if rendered_start_idx <= 0 or _is_updating_scroll or not is_inside_tree():
		return
	_is_updating_scroll = true
	var load_count = min(BATCH_SIZE, rendered_start_idx)
	var new_start = rendered_start_idx - load_count
	var old_h = message_vbox.size.y

	for i in range(rendered_start_idx - 1, new_start - 1, -1):
		var node = _create_message_node(messages_data[i])
		message_vbox.add_child(node)
		message_vbox.move_child(node, 0)
	rendered_start_idx = new_start

	# Prune from bottom if exceeded MAX_RENDERED
	while message_vbox.get_child_count() > MAX_RENDERED and rendered_end_idx > (rendered_start_idx + BATCH_SIZE):
		var last_idx = message_vbox.get_child_count() - 1
		var last = message_vbox.get_child(last_idx)
		message_vbox.remove_child(last)
		last.queue_free()
		rendered_end_idx -= 1

	await get_tree().process_frame
	if is_instance_valid(scroll_container) and is_instance_valid(message_vbox):
		var diff = message_vbox.size.y - old_h
		var scrollbar = scroll_container.get_v_scroll_bar()
		if scrollbar:
			scrollbar.value += diff
	_is_updating_scroll = false

	# Re-check scroll position in case user continued scrolling during frame delay
	if is_instance_valid(scroll_container):
		var scrollbar = scroll_container.get_v_scroll_bar()
		if scrollbar and scrollbar.value <= PREFETCH_MARGIN and rendered_start_idx > 0:
			_load_older_messages()

func _load_newer_messages(follow_to_bottom: bool = false):
	if rendered_end_idx >= messages_data.size() or _is_updating_scroll or not is_inside_tree():
		return
	_is_updating_scroll = true

	if follow_to_bottom:
		for c in message_vbox.get_children():
			message_vbox.remove_child(c)
			c.queue_free()
		var total = messages_data.size()
		rendered_start_idx = max(0, total - MAX_RENDERED)
		rendered_end_idx = total
		for i in range(rendered_start_idx, rendered_end_idx):
			message_vbox.add_child(_create_message_node(messages_data[i]))
		
		await get_tree().process_frame
		if is_instance_valid(scroll_container):
			var scrollbar = scroll_container.get_v_scroll_bar()
			if scrollbar:
				scrollbar.value = scrollbar.max_value
				if jump_to_bottom_btn:
					jump_to_bottom_btn.text = "V"
					jump_to_bottom_btn.hide()
		_is_updating_scroll = false
		return

	var remaining = messages_data.size() - rendered_end_idx
	var load_count = min(BATCH_SIZE, remaining)
	var new_end = rendered_end_idx + load_count

	for i in range(rendered_end_idx, new_end):
		var node = _create_message_node(messages_data[i])
		message_vbox.add_child(node)
	rendered_end_idx = new_end

	# Prune from top if exceeded MAX_RENDERED
	var scrollbar = scroll_container.get_v_scroll_bar()
	var old_scroll = scrollbar.value if scrollbar else 0.0
	var old_h = message_vbox.size.y
	var pruned_any = false

	while message_vbox.get_child_count() > MAX_RENDERED and rendered_start_idx < (rendered_end_idx - BATCH_SIZE):
		var first = message_vbox.get_child(0)
		message_vbox.remove_child(first)
		first.queue_free()
		rendered_start_idx += 1
		pruned_any = true

	await get_tree().process_frame
	if is_instance_valid(scroll_container) and is_instance_valid(message_vbox):
		scrollbar = scroll_container.get_v_scroll_bar()
		if scrollbar:
			if pruned_any:
				var height_removed = old_h - message_vbox.size.y
				if height_removed > 0:
					scrollbar.value = max(0.0, old_scroll - height_removed)

	_is_updating_scroll = false

	# Re-check scroll position in case user reached bottom or stayed in prefetch zone
	if is_instance_valid(scroll_container):
		scrollbar = scroll_container.get_v_scroll_bar()
		if scrollbar:
			var at_bottom = scrollbar.value >= (scrollbar.max_value - scrollbar.page - 25.0)
			if at_bottom and rendered_end_idx < messages_data.size():
				_load_newer_messages(true)
			elif scrollbar.value >= (scrollbar.max_value - scrollbar.page - PREFETCH_MARGIN) and rendered_end_idx < messages_data.size():
				_load_newer_messages(false)

func add_message(msg_data: Dictionary):
	var scrollbar = scroll_container.get_v_scroll_bar()
	var is_at_bottom = scrollbar.value >= (scrollbar.max_value - scrollbar.page - 25.0)

	if not messages_data.has(msg_data):
		messages_data.append(msg_data)

	if msg_data.get("pinned", false):
		_update_pinned_count()

	# If viewing the bottom of the chat, append directly to active window
	if is_at_bottom or rendered_end_idx == (messages_data.size() - 1):
		var node = _create_message_node(msg_data)
		message_vbox.add_child(node)
		rendered_end_idx = messages_data.size()

		# Prune top child if window capacity exceeded
		if message_vbox.get_child_count() > MAX_RENDERED:
			var oldest = message_vbox.get_child(0)
			message_vbox.remove_child(oldest)
			oldest.queue_free()
			rendered_start_idx += 1

		call_deferred("_scroll_to_bottom")
	else:
		# User is scrolled up: notify with jump button badge without allocating heavy nodes
		jump_to_bottom_btn.text = "V (New)"
		jump_to_bottom_btn.show()

func set_messages(history: Array):
	messages_data = history
	_update_pinned_count()
	_rebuild_rendered_messages(true)

func _rebuild_rendered_messages(scroll_to_bottom: bool = false):
	for c in message_vbox.get_children():
		c.queue_free()

	var total = messages_data.size()
	rendered_start_idx = max(0, total - MAX_RENDERED)
	rendered_end_idx = total

	for i in range(rendered_start_idx, rendered_end_idx):
		message_vbox.add_child(_create_message_node(messages_data[i]))

	if scroll_to_bottom:
		call_deferred("_scroll_to_bottom")

func _scroll_to_bottom():
	if not is_inside_tree() or get_tree() == null:
		return
	# Await 2 frames to allow ScrollContainer and children layout calculations to settle
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or not scroll_container or not is_instance_valid(scroll_container):
		return
	var scrollbar = scroll_container.get_v_scroll_bar()
	if scrollbar and is_instance_valid(scrollbar):
		scrollbar.value = scrollbar.max_value
		if jump_to_bottom_btn:
			jump_to_bottom_btn.text = "V"
			jump_to_bottom_btn.hide()

func _create_message_node(m: Dictionary, is_in_pinned_dialog: bool = false) -> Control:
	var type = m.get("type", "text")

	if type == "join":
		var lbl = Label.new()
		lbl.text = m.get("text", "User joined")
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 0.5))
		return lbl

	if type == "command_echo":
		var mcontainer = MarginContainer.new()
		mcontainer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mcontainer.mouse_filter = Control.MOUSE_FILTER_PASS
		var rtl = RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.fit_content = true
		rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rtl.selection_enabled = true
		rtl.mouse_filter = Control.MOUSE_FILTER_PASS
		rtl.text = "[color=#888888]> " + m.get("text", "").replace("[", "[lb]") + "[/color]"
		mcontainer.add_child(rtl)
		return mcontainer

	if type == "command_response":
		var mcontainer = MarginContainer.new()
		mcontainer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mcontainer.mouse_filter = Control.MOUSE_FILTER_PASS
		var rtl = RichTextLabel.new()
		rtl.bbcode_enabled = true
		rtl.fit_content = true
		rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rtl.selection_enabled = true
		rtl.mouse_filter = Control.MOUSE_FILTER_PASS
		rtl.text = m.get("text", "")
		mcontainer.add_child(rtl)
		return mcontainer

	var mcontainer = MarginContainer.new()
	mcontainer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mcontainer.mouse_filter = Control.MOUSE_FILTER_PASS

	var content_vbox = VBoxContainer.new()
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	mcontainer.add_child(content_vbox)

	var rtl = RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.selection_enabled = true
	rtl.mouse_filter = Control.MOUSE_FILTER_PASS

	var sender_name = m.get("sender_name", "Unknown")
	var color = m.get("sender_color", "ffffff")
	if color is Color:
		color = color.to_html(false)
	elif color is String and color.length() > 6:
		color = color.left(6)

	var pin_badge = "[color=yellow]📌[/color] " if (m.get("pinned", false) and not is_in_pinned_dialog) else ""

	if type == "text":
		var text = m.get("text", "")
		text = text.replace("[", "[lb]")
		rtl.text = pin_badge + "[color=#" + color + "][b]" + sender_name + ":[/b][/color] " + text
		content_vbox.add_child(rtl)
	elif type == "image":
		rtl.text = pin_badge + "[color=#" + color + "][b]" + sender_name + ":[/b][/color]"
		content_vbox.add_child(rtl)

		var img_hash = m.get("image_hash", "")
		var path = m.get("path", "")
		var file_path = ""
		if img_hash != "":
			file_path = "user://team_create_chat".path_join(img_hash + ".png")
		elif path != "":
			file_path = path

		var tex = _chat_texture_cache.get(file_path, null)
		if not tex and file_path != "":
			var img = null
			if FileAccess.file_exists(file_path):
				img = Image.load_from_file(file_path)
			elif ResourceLoader.exists(file_path):
				var res = load(file_path)
				if res is Texture2D:
					img = res.get_image()
			if img and not img.is_empty():
				tex = ImageTexture.create_from_image(img)
				_chat_texture_cache[file_path] = tex

		if tex:
			var tex_rect = TextureRect.new()
			tex_rect.texture = tex
			tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var max_w = 260.0
			var w = min(float(tex.get_width()), max_w)
			var h = (float(tex.get_height()) / float(tex.get_width())) * w if tex.get_width() > 0 else 100.0
			tex_rect.custom_minimum_size = Vector2(w, h)
			tex_rect.mouse_filter = Control.MOUSE_FILTER_PASS
			tex_rect.tooltip_text = "Click to open image in system viewer"
			var target_file_path = file_path
			tex_rect.gui_input.connect(func(event: InputEvent):
				if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
					OS.shell_open(ProjectSettings.globalize_path(target_file_path))
			)
			content_vbox.add_child(tex_rect)
		else:
			if network and network.has_method("get_chat_image_path") and img_hash != "":
				network.get_chat_image_path(img_hash)
			var fallback_lbl = Label.new()
			fallback_lbl.text = "[Image: " + (img_hash.substr(0, 8) if img_hash != "" else path.get_file()) + "]"
			fallback_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			content_vbox.add_child(fallback_lbl)

	# Pin button
	if m.has("id") and m["id"] != -1:
		var pin_btn = Button.new()
		if is_in_pinned_dialog:
			pin_btn.text = "Unpin"
			pin_btn.tooltip_text = "Remove from pinned messages"
		else:
			pin_btn.text = "📌" if m.get("pinned", false) else "📍"
			pin_btn.tooltip_text = "Unpin" if m.get("pinned", false) else "Pin message"
		pin_btn.flat = true
		pin_btn.add_theme_font_size_override("font_size", 10)
		pin_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
		pin_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		var msg_id = m["id"]
		pin_btn.pressed.connect(func():
			if network:
				network.toggle_pin_message(msg_id)
		)
		mcontainer.add_child(pin_btn)

	return mcontainer

func refresh_images():
	_chat_texture_cache.clear()
	var scrollbar = scroll_container.get_v_scroll_bar()
	var is_at_bottom = scrollbar.value >= (scrollbar.max_value - scrollbar.page - 25.0)
	_rebuild_rendered_messages(is_at_bottom)
