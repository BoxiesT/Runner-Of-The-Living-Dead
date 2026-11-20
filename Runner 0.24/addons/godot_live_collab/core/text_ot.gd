@tool
class_name GLCTextOT
extends RefCounted
## Operational Transformation for plain text (retain / insert / delete components).
##
## An operation is a list of components applied left-to-right over a document:
##   int  > 0  -> retain N characters
##   int  < 0  -> delete N characters
##   String    -> insert that text
## It satisfies TP1 (see tests): for concurrent ops a, b over the same document,
##   apply(apply(S, a), b') == apply(apply(S, b), a')   with   [a', b'] = transform(a, b)
##
## Also contains a Jupiter-style `Client` / `Server` pair (one op in flight, one buffered op),
## which is how GLCScriptLiveSync keeps every CodeEdit identical.

var ops: Array = []
var base_length: int = 0
var target_length: int = 0

# ---------------------------------------------------------------- building

static func is_retain(op: Variant) -> bool:
	return typeof(op) == TYPE_INT and int(op) > 0

static func is_delete(op: Variant) -> bool:
	return typeof(op) == TYPE_INT and int(op) < 0

static func is_insert(op: Variant) -> bool:
	return typeof(op) == TYPE_STRING

func retain(n: int) -> GLCTextOT:
	if n <= 0:
		return self
	base_length += n
	target_length += n
	if not ops.is_empty() and is_retain(ops[-1]):
		ops[-1] = int(ops[-1]) + n
	else:
		ops.append(n)
	return self

func delete(n: int) -> GLCTextOT:
	if n == 0:
		return self
	if n < 0:
		n = -n
	base_length += n
	if not ops.is_empty() and is_delete(ops[-1]):
		ops[-1] = int(ops[-1]) - n
	else:
		ops.append(-n)
	return self

func insert(s: String) -> GLCTextOT:
	if s.is_empty():
		return self
	target_length += s.length()
	if ops.is_empty():
		ops.append(s)
	elif is_insert(ops[-1]):
		ops[-1] = String(ops[-1]) + s
	elif is_delete(ops[-1]):
		# canonical form: an insert always precedes an adjacent delete
		if ops.size() >= 2 and is_insert(ops[-2]):
			ops[-2] = String(ops[-2]) + s
		else:
			ops.insert(ops.size() - 1, s)
	else:
		ops.append(s)
	return self

func is_noop() -> bool:
	return ops.is_empty() or (ops.size() == 1 and is_retain(ops[0]))

func duplicate_op() -> GLCTextOT:
	var o := GLCTextOT.new()
	o.ops = ops.duplicate()
	o.base_length = base_length
	o.target_length = target_length
	return o

func to_array() -> Array:
	return ops.duplicate()

static func from_array(arr: Array) -> GLCTextOT:
	var o := GLCTextOT.new()
	for c in arr:
		if typeof(c) == TYPE_STRING:
			o.insert(c)
		elif typeof(c) == TYPE_INT or typeof(c) == TYPE_FLOAT:
			var n := int(c)
			if n > 0:
				o.retain(n)
			elif n < 0:
				o.delete(-n)
	return o

func _to_string() -> String:
	return "TextOp(%s | %d->%d)" % [str(ops), base_length, target_length]

# ---------------------------------------------------------------- apply

func apply(doc: String) -> String:
	if doc.length() != base_length:
		push_warning("GLCTextOT.apply: base length mismatch (%d vs %d)" % [doc.length(), base_length])
		return doc
	var parts := PackedStringArray()
	var idx := 0
	for c in ops:
		if is_retain(c):
			parts.append(doc.substr(idx, int(c)))
			idx += int(c)
		elif is_insert(c):
			parts.append(String(c))
		else:
			idx += -int(c)
	return "".join(parts)

## Index mapping through the operation. `after` decides whether a position that sits exactly at an
## insertion point is pushed after the inserted text (true) or stays before it (false).
func transform_index(index: int, after: bool = true) -> int:
	var new_index := index
	var pos := 0
	for c in ops:
		if is_retain(c):
			pos += int(c)
		elif is_insert(c):
			if pos < index or (after and pos == index):
				new_index += String(c).length()
		else:
			var n := -int(c)
			if pos < index:
				new_index -= mini(n, index - pos)
			pos += n
		if pos > index:
			break
	return maxi(0, new_index)

# ---------------------------------------------------------------- compose / transform

static func _next(arr: Array, i: int) -> Variant:
	return arr[i] if i < arr.size() else null

static func compose(a: GLCTextOT, b: GLCTextOT) -> GLCTextOT:
	var res := GLCTextOT.new()
	if a.target_length != b.base_length:
		push_error("GLCTextOT.compose: length mismatch (%d vs %d)" % [a.target_length, b.base_length])
		return res
	var i1 := 1
	var i2 := 1
	var op1: Variant = _next(a.ops, 0)
	var op2: Variant = _next(b.ops, 0)
	while true:
		if op1 == null and op2 == null:
			break
		if is_delete(op1):
			res.delete(-int(op1))
			op1 = _next(a.ops, i1)
			i1 += 1
			continue
		if is_insert(op2):
			res.insert(String(op2))
			op2 = _next(b.ops, i2)
			i2 += 1
			continue
		if op1 == null or op2 == null:
			push_error("GLCTextOT.compose: operations too short")
			break
		if is_retain(op1) and is_retain(op2):
			var r1 := int(op1)
			var r2 := int(op2)
			if r1 > r2:
				res.retain(r2)
				op1 = r1 - r2
				op2 = _next(b.ops, i2)
				i2 += 1
			elif r1 == r2:
				res.retain(r1)
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				res.retain(r1)
				op2 = r2 - r1
				op1 = _next(a.ops, i1)
				i1 += 1
		elif is_insert(op1) and is_delete(op2):
			var s1 := String(op1)
			var d2 := -int(op2)
			if s1.length() > d2:
				op1 = s1.substr(d2)
				op2 = _next(b.ops, i2)
				i2 += 1
			elif s1.length() == d2:
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				op2 = -(d2 - s1.length())
				op1 = _next(a.ops, i1)
				i1 += 1
		elif is_insert(op1) and is_retain(op2):
			var s1b := String(op1)
			var r2b := int(op2)
			if s1b.length() > r2b:
				res.insert(s1b.substr(0, r2b))
				op1 = s1b.substr(r2b)
				op2 = _next(b.ops, i2)
				i2 += 1
			elif s1b.length() == r2b:
				res.insert(s1b)
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				res.insert(s1b)
				op2 = r2b - s1b.length()
				op1 = _next(a.ops, i1)
				i1 += 1
		elif is_retain(op1) and is_delete(op2):
			var r1c := int(op1)
			var d2c := -int(op2)
			if r1c > d2c:
				res.delete(d2c)
				op1 = r1c - d2c
				op2 = _next(b.ops, i2)
				i2 += 1
			elif r1c == d2c:
				res.delete(d2c)
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				res.delete(r1c)
				op2 = -(d2c - r1c)
				op1 = _next(a.ops, i1)
				i1 += 1
		else:
			push_error("GLCTextOT.compose: unexpected component pair")
			break
	return res

## Returns [a', b'] with  apply(apply(S,a), b') == apply(apply(S,b), a').
## On equal-position inserts, `a` is placed first (a has priority).
static func transform(a: GLCTextOT, b: GLCTextOT) -> Array:
	var a2 := GLCTextOT.new()
	var b2 := GLCTextOT.new()
	if a.base_length != b.base_length:
		push_error("GLCTextOT.transform: base length mismatch (%d vs %d)" % [a.base_length, b.base_length])
		return [a2, b2]
	var i1 := 1
	var i2 := 1
	var op1: Variant = _next(a.ops, 0)
	var op2: Variant = _next(b.ops, 0)
	while true:
		if op1 == null and op2 == null:
			break
		if is_insert(op1):
			a2.insert(String(op1))
			b2.retain(String(op1).length())
			op1 = _next(a.ops, i1)
			i1 += 1
			continue
		if is_insert(op2):
			a2.retain(String(op2).length())
			b2.insert(String(op2))
			op2 = _next(b.ops, i2)
			i2 += 1
			continue
		if op1 == null or op2 == null:
			push_error("GLCTextOT.transform: operations too short")
			break
		var minl := 0
		if is_retain(op1) and is_retain(op2):
			var r1 := int(op1)
			var r2 := int(op2)
			if r1 > r2:
				minl = r2
				op1 = r1 - r2
				op2 = _next(b.ops, i2)
				i2 += 1
			elif r1 == r2:
				minl = r2
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				minl = r1
				op2 = r2 - r1
				op1 = _next(a.ops, i1)
				i1 += 1
			a2.retain(minl)
			b2.retain(minl)
		elif is_delete(op1) and is_delete(op2):
			var d1 := -int(op1)
			var d2 := -int(op2)
			if d1 > d2:
				op1 = -(d1 - d2)
				op2 = _next(b.ops, i2)
				i2 += 1
			elif d1 == d2:
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				op2 = -(d2 - d1)
				op1 = _next(a.ops, i1)
				i1 += 1
		elif is_delete(op1) and is_retain(op2):
			var d1b := -int(op1)
			var r2b := int(op2)
			if d1b > r2b:
				minl = r2b
				op1 = -(d1b - r2b)
				op2 = _next(b.ops, i2)
				i2 += 1
			elif d1b == r2b:
				minl = r2b
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				minl = d1b
				op2 = r2b - d1b
				op1 = _next(a.ops, i1)
				i1 += 1
			a2.delete(minl)
		elif is_retain(op1) and is_delete(op2):
			var r1c := int(op1)
			var d2c := -int(op2)
			if r1c > d2c:
				minl = d2c
				op1 = r1c - d2c
				op2 = _next(b.ops, i2)
				i2 += 1
			elif r1c == d2c:
				minl = r1c
				op1 = _next(a.ops, i1)
				i1 += 1
				op2 = _next(b.ops, i2)
				i2 += 1
			else:
				minl = r1c
				op2 = -(d2c - r1c)
				op1 = _next(a.ops, i1)
				i1 += 1
			b2.delete(minl)
		else:
			push_error("GLCTextOT.transform: unexpected component pair")
			break
	return [a2, b2]

# ---------------------------------------------------------------- diff (old text -> new text)

const _CHAR_DP_LIMIT := 6000       # max cells for char-level LCS
const _LINE_DP_LIMIT := 60000      # max cells for line-level LCS

static func identity(length: int) -> GLCTextOT:
	var o := GLCTextOT.new()
	o.retain(length)
	return o

static func _common_prefix(a: String, b: String) -> int:
	var n := mini(a.length(), b.length())
	var i := 0
	while i + 64 <= n and a.substr(i, 64) == b.substr(i, 64):
		i += 64
	while i < n and a.unicode_at(i) == b.unicode_at(i):
		i += 1
	return i

static func _common_suffix(a: String, b: String, max_len: int) -> int:
	var la := a.length()
	var lb := b.length()
	var n := mini(max_len, mini(la, lb))
	var i := 0
	while i + 64 <= n and a.substr(la - i - 64, 64) == b.substr(lb - i - 64, 64):
		i += 64
	while i < n and a.unicode_at(la - 1 - i) == b.unicode_at(lb - 1 - i):
		i += 1
	return i

## Minimal-ish op turning `old_text` into `new_text` (multi-hunk when the changed region is small).
static func from_diff(old_text: String, new_text: String) -> GLCTextOT:
	var op := GLCTextOT.new()
	if old_text == new_text:
		return op.retain(old_text.length())
	var pre := _common_prefix(old_text, new_text)
	var suf := _common_suffix(old_text, new_text, mini(old_text.length(), new_text.length()) - pre)
	var old_mid := old_text.substr(pre, old_text.length() - pre - suf)
	var new_mid := new_text.substr(pre, new_text.length() - pre - suf)
	op.retain(pre)
	_diff_region(op, old_mid, new_mid)
	op.retain(suf)
	return op

static func _diff_region(op: GLCTextOT, a: String, b: String) -> void:
	if a.is_empty():
		op.insert(b)
		return
	if b.is_empty():
		op.delete(a.length())
		return
	if a.length() * b.length() <= _CHAR_DP_LIMIT:
		_diff_chars(op, a, b)
		return
	var la := _tokenize_lines(a)
	var lb := _tokenize_lines(b)
	var p := 0
	var n := mini(la.size(), lb.size())
	while p < n and la[p] == lb[p]:
		p += 1
	var s := 0
	while s < n - p and la[la.size() - 1 - s] == lb[lb.size() - 1 - s]:
		s += 1
	for i in p:
		op.retain(String(la[i]).length())
	var ma := la.slice(p, la.size() - s)
	var mb := lb.slice(p, lb.size() - s)
	if ma.size() * mb.size() <= _LINE_DP_LIMIT and not ma.is_empty() and not mb.is_empty():
		_diff_line_arrays(op, ma, mb)
	else:
		_replace_block(op, ma, mb)
	for i in s:
		op.retain(String(la[la.size() - s + i]).length())

static func _tokenize_lines(s: String) -> Array:
	var out: Array = []
	var parts := s.split("\n", true)
	for i in parts.size():
		if i < parts.size() - 1:
			out.append(parts[i] + "\n")
		elif not parts[i].is_empty():
			out.append(parts[i])
	return out

static func _join(lines: Array) -> String:
	return "".join(PackedStringArray(lines))

static func _replace_block(op: GLCTextOT, ma: Array, mb: Array) -> void:
	if ma.size() == mb.size() and not ma.is_empty():
		for i in ma.size():
			var sa := String(ma[i])
			var sb := String(mb[i])
			var pre := _common_prefix(sa, sb)
			var suf := _common_suffix(sa, sb, mini(sa.length(), sb.length()) - pre)
			op.retain(pre)
			op.insert(sb.substr(pre, sb.length() - pre - suf))
			op.delete(sa.length() - pre - suf)
			op.retain(suf)
		return
	op.insert(_join(mb))
	op.delete(_join(ma).length())

static func _diff_line_arrays(op: GLCTextOT, ma: Array, mb: Array) -> void:
	var n := ma.size()
	var m := mb.size()
	var w := m + 1
	var t := PackedInt32Array()
	t.resize((n + 1) * w)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if ma[i] == mb[j]:
				t[i * w + j] = t[(i + 1) * w + j + 1] + 1
			else:
				t[i * w + j] = maxi(t[(i + 1) * w + j], t[i * w + j + 1])
	var i := 0
	var j := 0
	var del_blk: Array = []
	var ins_blk: Array = []
	while i < n or j < m:
		if i < n and j < m and ma[i] == mb[j]:
			if not del_blk.is_empty() or not ins_blk.is_empty():
				_replace_block(op, del_blk, ins_blk)
				del_blk = []
				ins_blk = []
			op.retain(String(ma[i]).length())
			i += 1
			j += 1
		elif j < m and (i >= n or t[i * w + j + 1] >= t[(i + 1) * w + j]):
			ins_blk.append(mb[j])
			j += 1
		else:
			del_blk.append(ma[i])
			i += 1
	if not del_blk.is_empty() or not ins_blk.is_empty():
		_replace_block(op, del_blk, ins_blk)

static func _diff_chars(op: GLCTextOT, a: String, b: String) -> void:
	var n := a.length()
	var m := b.length()
	var w := m + 1
	var t := PackedInt32Array()
	t.resize((n + 1) * w)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if a.unicode_at(i) == b.unicode_at(j):
				t[i * w + j] = t[(i + 1) * w + j + 1] + 1
			else:
				t[i * w + j] = maxi(t[(i + 1) * w + j], t[i * w + j + 1])
	var i := 0
	var j := 0
	while i < n or j < m:
		if i < n and j < m and a.unicode_at(i) == b.unicode_at(j):
			op.retain(1)
			i += 1
			j += 1
		elif j < m and (i >= n or t[i * w + j + 1] >= t[(i + 1) * w + j]):
			op.insert(b.substr(j, 1))
			j += 1
		else:
			op.delete(1)
			i += 1

# ---------------------------------------------------------------- Jupiter-style client / server

## Client side of one document. Holds at most one op "in flight" plus one composed buffer.
class Client extends RefCounted:
	enum State { SYNCED, AWAITING, BUFFERED }
	var state: int = State.SYNCED
	var revision: int = 0
	var outstanding: GLCTextOT = null
	var buffer: GLCTextOT = null

	## Local edit made by the user. Returns the op that must be sent now (or null if it was buffered).
	func apply_local(op: GLCTextOT) -> GLCTextOT:
		match state:
			State.SYNCED:
				outstanding = op
				state = State.AWAITING
				return op
			State.AWAITING:
				buffer = op
				state = State.BUFFERED
				return null
			_:
				buffer = GLCTextOT.compose(buffer, op)
				return null

	## Operation from the server (already ordered). Returns the op to apply to the local editor.
	func apply_server(op: GLCTextOT) -> GLCTextOT:
		revision += 1
		match state:
			State.SYNCED:
				return op
			State.AWAITING:
				var pair := GLCTextOT.transform(outstanding, op)
				outstanding = pair[0]
				return pair[1]
			_:
				var pair1 := GLCTextOT.transform(outstanding, op)
				var pair2 := GLCTextOT.transform(buffer, pair1[1])
				outstanding = pair1[0]
				buffer = pair2[0]
				return pair2[1]

	## Server acknowledged our in-flight op. Returns the next op to send (the buffer) or null.
	func server_ack() -> GLCTextOT:
		revision += 1
		match state:
			State.AWAITING:
				outstanding = null
				state = State.SYNCED
				return null
			State.BUFFERED:
				outstanding = buffer
				buffer = null
				state = State.AWAITING
				return outstanding
		return null

	func reset(rev: int) -> void:
		state = State.SYNCED
		revision = rev
		outstanding = null
		buffer = null

## Server (host) side of one document: ordered history + text.
class Server extends RefCounted:
	var text: String = ""
	var history: Array = []     # Array[GLCTextOT]; history[i] produced revision base_revision+i+1
	var base_revision: int = 0
	const MAX_HISTORY := 2000

	func revision() -> int:
		return base_revision + history.size()

	## A client op created when that client had incorporated `rev` server revisions.
	## Returns the transformed op that was applied, or null if `rev` is unknown (client must resync).
	func receive(rev: int, op: GLCTextOT) -> GLCTextOT:
		var start := rev - base_revision
		if start < 0 or start > history.size():
			return null
		var cur := op
		for i in range(start, history.size()):
			cur = GLCTextOT.transform(cur, history[i])[0]
		if cur.base_length != text.length():
			return null
		text = cur.apply(text)
		history.append(cur)
		if history.size() > MAX_HISTORY:
			var drop := history.size() - MAX_HISTORY
			history = history.slice(drop)
			base_revision += drop
		return cur

	## Local (host editor) edit: already in server coordinates.
	func apply_local(op: GLCTextOT) -> GLCTextOT:
		return receive(revision(), op)
