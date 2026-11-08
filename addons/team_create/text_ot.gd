@tool
extends RefCounted

## Team Create - Text operations for merging edits made at the same time
## An operation walks the whole text from start to end as a list of steps: a positive int keeps that many
## characters, a negative int deletes that many, and a String inserts itself. Because every operation accounts
## for the whole text, two made at the same time can be rewritten to apply one after the other.

static func _add_retain(ops: Array, count: int) -> void:
	if count == 0:
		return
	if not ops.is_empty() and ops[-1] is int and ops[-1] > 0:
		ops[-1] += count
	else:
		ops.append(count)

static func _add_delete(ops: Array, count: int) -> void:
	if count == 0:
		return
	if not ops.is_empty() and ops[-1] is int and ops[-1] < 0:
		ops[-1] -= count
	else:
		ops.append(-count)

# An insert always goes before a delete next to it, so the same edit always has the same steps
static func _add_insert(ops: Array, text: String) -> void:
	if text == "":
		return
	if not ops.is_empty() and ops[-1] is String:
		ops[-1] += text
	elif not ops.is_empty() and ops[-1] is int and ops[-1] < 0:
		if ops.size() >= 2 and ops[-2] is String:
			ops[-2] += text
		else:
			ops.insert(ops.size() - 1, text)
	else:
		ops.append(text)

static func input_length(op: Array) -> int:
	var total = 0
	for step in op:
		if step is int:
			total += absi(step)
	return total

# False for anything that isn't a well formed operation, since these arrive from the network
static func is_valid(op: Array) -> bool:
	for step in op:
		if not (step is String or (step is int and step != 0)):
			return false
	return true

static func apply(text: String, op: Array) -> String:
	var pieces = PackedStringArray()
	var position = 0
	for step in op:
		if step is String:
			pieces.append(step)
		elif step > 0:
			pieces.append(text.substr(position, step))
			position += step
		else:
			position -= step
	return "".join(pieces)

static func _common_prefix(a: String, b: String) -> int:
	var low = 0
	var high = mini(a.length(), b.length())
	while low < high:
		var middle = (low + high + 1) / 2
		if a.substr(low, middle - low) == b.substr(low, middle - low):
			low = middle
		else:
			high = middle - 1
	return low

static func _common_suffix(a: String, b: String, limit: int) -> int:
	var low = 0
	var high = limit
	while low < high:
		var middle = (low + high + 1) / 2
		if a.substr(a.length() - middle, middle - low) == b.substr(b.length() - middle, middle - low):
			low = middle
		else:
			high = middle - 1
	return low

# The operation turning old_text into new_text, as one replaced range
static func diff(old_text: String, new_text: String) -> Array:
	var prefix = _common_prefix(old_text, new_text)
	var suffix = _common_suffix(old_text, new_text, mini(old_text.length(), new_text.length()) - prefix)
	var op = []
	_add_retain(op, prefix)
	_add_insert(op, new_text.substr(prefix, new_text.length() - prefix - suffix))
	_add_delete(op, old_text.length() - prefix - suffix)
	_add_retain(op, suffix)
	return op

# Rewrites two operations made on the same text, as [a_after_b, b_after_a]. Where both insert at the same spot,
# a's text comes first. Text inserted inside a range the other deleted survives.
static func transform(a: Array, b: Array) -> Array:
	var a_out = []
	var b_out = []
	var i = 0
	var j = 0
	var step_a = a[0] if a.size() > 0 else null
	var step_b = b[0] if b.size() > 0 else null
	while step_a != null or step_b != null:
		if step_a is String:
			_add_insert(a_out, step_a)
			_add_retain(b_out, step_a.length())
			i += 1
			step_a = a[i] if i < a.size() else null
			continue
		if step_b is String:
			_add_retain(a_out, step_b.length())
			_add_insert(b_out, step_b)
			j += 1
			step_b = b[j] if j < b.size() else null
			continue
		var count = mini(absi(step_a), absi(step_b))
		if step_a > 0 and step_b > 0:
			_add_retain(a_out, count)
			_add_retain(b_out, count)
		elif step_a < 0 and step_b > 0:
			_add_delete(a_out, count)
		elif step_a > 0 and step_b < 0:
			_add_delete(b_out, count)
		step_a = step_a - count if step_a > 0 else step_a + count
		step_b = step_b - count if step_b > 0 else step_b + count
		if step_a == 0:
			i += 1
			step_a = a[i] if i < a.size() else null
		if step_b == 0:
			j += 1
			step_b = b[j] if j < b.size() else null
	return [a_out, b_out]

# One operation that does what a and then b does
static func compose(a: Array, b: Array) -> Array:
	var out = []
	var i = 0
	var j = 0
	var step_a = a[0] if a.size() > 0 else null
	var step_b = b[0] if b.size() > 0 else null
	while step_a != null or step_b != null:
		if step_a is int and step_a < 0:
			_add_delete(out, -step_a)
			i += 1
			step_a = a[i] if i < a.size() else null
			continue
		if step_b is String:
			_add_insert(out, step_b)
			j += 1
			step_b = b[j] if j < b.size() else null
			continue
		var length_a = step_a.length() if step_a is String else step_a
		var count = mini(length_a, absi(step_b))
		if step_a is String:
			if step_b > 0:
				_add_insert(out, step_a.substr(0, count))
			step_a = step_a.substr(count)
			if step_a == "":
				step_a = 0
		else:
			if step_b > 0:
				_add_retain(out, count)
			else:
				_add_delete(out, count)
			step_a -= count
		step_b = step_b - count if step_b > 0 else step_b + count
		if step_a is int and step_a == 0:
			i += 1
			step_a = a[i] if i < a.size() else null
		if step_b == 0:
			j += 1
			step_b = b[j] if j < b.size() else null
	return out
