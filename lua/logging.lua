--[[

	File and TCP logging with capped disk & memory usage.
	Written by Cosmin Apreutesei. Public domain.

LOGGING
	logging.log(severity, module, event, fmt, ...)
	logging.note(module, event, fmt, ...)
	logging.dbg(module, event, fmt, ...)
	logging.warnif(module, event, condition, fmt, ...)
	logging.logerror(module, event, fmt, ...)
	logging.logvar(k, v)
	logging.live(e, [fmt, ...] | nil)
UTILS
	logging.arg(v) -> s
	logging.printarg(v) -> s
	logging.args(...) -> ...
	logging.printargs(...) -> ...
CONFIG
	logging.deploy            app deployment name (logged to server)
	logging.env               app deployment type: 'dev', 'prod', etc.
	logging.quiet             do not log anything to stderr (false)
	logging.verbose           log `note` messages to stderr (false)
	logging.debug             log `debug` messages to stderr (false)
	logging.flush             flush stderr after each message (false)
	logging.max_disk_size     max disk size occupied by logging (16M)
	logging.queue_size        queue size for when the server is slow (10000)
	logging.timeout           timeout (5)
	logging.filter.severity = true    |filter out messages of a specific severity
	logging.censor.name <- f(severity, module, ev, msg)  |set a function for censoring secrets in logs
INIT
	logging:tofile(logfile, max_disk_size)
	logging:toserver(host, port, queue_size, timeout)

Logging is done to stderr by default. To start logging to a file, call
logging:tofile(). To start logging to a server, call logging:toserver().
You can call both.

]]

local ffi = require'ffi'
local time = require'time'
local pp = require'pp'
local glue = require'glue'

local clock = time.clock
local time = time.time
local _ = string.format

local logging = {
	quiet = false,
	verbose = false,
	debug = false,
	flush = false, --too slow (but you can tail)
	censor = {},
	max_disk_size = 16 * 1024^2,
	queue_size = 10000,
	timeout = 5,
}

function logging:tofile(logfile, max_size)

	local fs = require'fs'

	local logfile0 = logfile:gsub('(%.[^%.]+)$', '0%1')
	if logfile0 == logfile then logfile0 = logfile..'0' end

	local f, size

	local function open()
		if f then return true end
		f = fs.open(logfile, 'a')
		if not f then return end
		size = f:attr'size'
		if not f then return end
		return true
	end

	max_size = max_size or self.max_disk_size

	local function rotate(len)
		if max_size and size + len > max_size / 2 then
			f:close(); f = nil
			if not fs.move(logfile, logfile0) then return end
			if not open() then return end
		end
		return true
	end

	function self:logtofile(s)
		if not open() then return end
		if not rotate(#s + 1) then return end
		size = size + #s + 1
		if not f:write(s) then return end
		if self.flush then f:flush() end
	end

	function self:tofile_stop()
		if not f then return end
		f:close()
		f = nil
	end

	return self
end

function logging:toserver(host, port, queue_size, timeout)

	local sock = require'sock'
	local queue = require'queue'

	queue_size = queue_size or logging.queue_size
	timeout = timeout or logging.timeout

	local tcp

	local function check_io(ret, err)
		if ret then return ret end
		if tcp then tcp:close(); tcp = nil end
		return ret, err
	end

	local reconn_sleeper
	local stop

	local function connect()
		if tcp then return tcp end
		tcp = sock.tcp()
		if not tcp then return end
		while not stop do
			local exp = timeout and clock() + timeout
			if tcp:connect(host, port, exp) then
				self.live(tcp, 'connected logging %s:%d', host, port)
				return true
			end
			--wait because 'connection_refused' error comes instantly on Linux.
			if not stop and exp > clock() + 0.1 then
				reconn_sleeper = sock.sleep_job()
				reconn_sleeper:sleep_until(exp)
				reconn_sleeper = nil
			end
		end
		return false
	end

	local queue = queue.new(queue_size or 1/0)
	local send_thread_suspended = true

	local send_thread = sock.thread(function()
		send_thread_suspended = false
		local lenbuf = glue.u32a(1)
		while not stop do
			local msg = queue:peek()
			if msg then
				if connect() then
					local s = pp.format(msg)
					lenbuf[0] = #s
					local len = ffi.string(lenbuf, ffi.sizeof(lenbuf))
					local exp = timeout and clock() + timeout
					if check_io(tcp:send(len..s, nil, exp)) then
						queue:pop()
					end
				end
			else
				send_thread_suspended = true
				sock.suspend()
				send_thread_suspended = false
			end
		end
		check_io()
		self.logtoserver = nil
	end)

	function self:logtoserver(msg)
		if not queue:push(msg) then
			queue:pop()
			queue:push(msg)
		end
		if send_thread_suspended then
			sock.resume(send_thread)
		end
	end

	function self:toserver_stop()
		stop = true
		if send_thread_suspended then
			sock.resume(send_thread)
		elseif reconn_sleeper then
			reconn_sleeper:wakeup()
		end
	end

	return self
end

function logging:toserver_stop() end

logging.filter = {}

local names = setmetatable({}, {__mode = 'k'}) --{[obj]->name}

function logging.name(obj, name)
	names[obj] = name
end

do
	local main, is_main = coroutine.running()
	if is_main then
		logging.name(main, 'TM')
	end
end

local function debug_type(v)
	return type(v) == 'table' and v.type or type(v)
end

local prefixes = {
	thread = 'T',
	['function'] = 'f',
	cdata = 'c',
}

local function debug_prefix(v)
	return type(v) == 'table' and v.debug_prefix
		or prefixes[debug_type(v)] or debug_type(v)
end

local ids_db = {} --{type->{last_id=,live=,[obj]->id}}
local mode_k = {__mode = 'k'}
local function debug_id(v)
	local ty = debug_type(v)
	local ids = ids_db[ty]
	if not ids then
		ids = setmetatable({
			live_count = 0,
			live = setmetatable({}, mode_k),
		}, mode_k)
		ids_db[ty] = ids
	end
	local id = ids[v]
	if not id then
		id = type(v) == 'table' and v.debug_id
		if not id then
			id = (ids.last_id or 0) + 1
			ids.last_id = id
		end
		ids[v] = id
	end
	return debug_prefix(v)..id, ids
end

local pp_skip = {
	__index = 1,
	__newindex = 1,
	__mode = 1,
}
local function pp_filter(v, k, t)
	if type(v) == 'function' then return true, '#'..debug_id(v) end --TODO
	if getmetatable(t) == t and pp_skip[k] then return end --skip inherits.
	return true, v
end
local function pp_onerror(err, v)
	if err == 'cycle' then return '(cycle)' end
	if err == 'unserializable' then return '#'..type(v) end
end
local pp_opt = {
	filter = pp_filter,
	onerror = pp_onerror,
}
local pp_opt_compact = {
	filter = pp_filter,
	onerror = pp_onerror,
	indent = false,
}
local function pp_compact(v)
	local s = pp.format(v, pp_opt)
	return #s < 50 and pp.format(v, pp_opt_compact) or s
end

local function debug_arg(for_printing, v)
	if v == nil then
		return 'nil'
	elseif type(v) == 'boolean' then
		return v and 'Y' or 'N'
	elseif type(v) == 'number' then
		return _('%.17g', v)
	else --string, table, function, thread, cdata
		v = type(v) == 'string' and v
			or names[v]
			or (getmetatable(v) and getmetatable(v).__tostring
				and not (type(v) == 'table' and v.type and v.debug_prefix)
				and tostring(v))
			or (type(v) == 'table' and not v.type and not v.debug_prefix and pp_compact(v))
			or debug_id(v)
		if not for_printing then
			if v:find('\n', 1, true) then --multiline, make room for it.
				v = v:gsub('\r\n', '\n')
				v = glue.outdent(v)
				v = v:gsub('\t', '   ')
				v = '\n\n'..v..'\n'
			end
			--avoid messing up the terminal when tailing logs.
			v = v:gsub('[%z\1-\8\11-\31\128-\255]', '.')
		end
		return v
	end
end
logging.arg       = function(v) return debug_arg(false, v) end
logging.printarg  = function(v) return debug_arg(true , v) end

local function logging_args_func(for_printing)
	return function(...)
		if select('#', ...) == 1 then
			return debug_arg(for_printing, (...))
		end
		local args, n = {...}, select('#',...)
		for i=1,n do
			args[i] = debug_arg(for_printing, args[i])
		end
		return unpack(args, 1, n)
	end
end
logging.args      = logging_args_func(false)
logging.printargs = logging_args_func(true)

local function log(self, severity, module, event, fmt, ...)
	if self.filter[severity] then return end
	if self.filter[module  ] then return end
	if self.filter[event   ] then return end
	self._logging = true
	local env = logging.env and logging.env:sub(1, 1):upper() or 'D'
	local time = time()
	local msg = fmt and _(fmt, self.args(...))
	if next(self.censor) then
		for _,censor in pairs(self.censor) do
			msg = censor(msg, self, severity, module, event)
		end
	end
	if msg and msg:find('\n', 1, true) then --multiline
		local arg1_multiline = msg:find'^\n\n'
		msg = glue.outdent(msg, '\t')
		if not arg1_multiline then
			msg = '\n\n'..msg..'\n'
		end
	end
	if (severity ~= '' or self.debug) and (severity ~= 'note' or self.verbose) then
		local entry = (self.logtofile or not self.quiet)
			and _('%s %s %-6s %-6s %-8s %-4s %s\n',
				env, os.date('%Y-%m-%d %H:%M:%S', time), severity,
				module or '', (event or ''):sub(1, 8),
				debug_arg(false, (coroutine.running())), msg or '')
		if not self._logging then
			self._logging = true
			if self.logtofile then
				self:logtofile(entry)
			end
			if self.logtoserver then
				self:logtoserver{
					deploy = self.deploy, env = logging.env, time = time,
					severity = severity, module = module, event = event,
					message = msg,
				}
			end
			self._logging = false
		end
		if not self.quiet then
			io.stderr:write(entry)
			io.stderr:flush()
		end
	end
end
local function note (self, ...) log(self, 'note', ...) end
local function dbg  (self, ...) log(self, '', ...) end

local function warnif(self, module, event, cond, ...)
	if not cond then return end
	log(self, 'WARN', module, event, ...)
end

local function logerror(self, module, event, ...)
	log(self, 'ERROR', module, event, ...)
end

local function logvar(self, k, v)
	if self.logtoserver then
		self:logtoserver{
			deploy = self.deploy, env = logging.env, time = time(),
			event = 'set', k = k, v = v,
		}
	end
end

local function live(self, o, fmt, ...)
	local id, ids = debug_id(o)
	local was_live = ids.live[id] ~= nil
	if fmt then
		if not was_live then
			ids.live_count = ids.live_count + 1
		end
	elseif was_live then
		ids.live_count = ids.live_count - 1
	end
	ids.live[id] = fmt and _(fmt, self.args(...)) or nil
end

local function liveadd(self, o, fmt, ...)
	local id, ids = debug_id(o)
	ids.live[id] = assert(ids.live[id]) .. ' ' .. _(fmt, self.args(...))
end

local function init(self)
	self.log      = function(...) return log      (self, ...) end
	self.note     = function(...) return note     (self, ...) end
	self.dbg      = function(...) return dbg      (self, ...) end
	self.warnif   = function(...) return warnif   (self, ...) end
	self.logerror = function(...) return logerror (self, ...) end
	self.logvar   = function(...) return logvar   (self, ...) end
	self.live     = function(...) return live     (self, ...) end
	self.liveadd  = function(...) return liveadd  (self, ...) end
	return self
end

function logging.printlive(custom_print)
	local print = custom_print or print
	for type, ids in pairs(ids_db) do
		print(_('%-12s: %d', type, ids.live_count))
		local t = {}; for k in pairs(ids.live) do t[#t+1] = k end
		table.sort(t)
		for i,id in ipairs(t) do
			print(_('  %-4s: %s', id, ids.live[id]))
		end
	end
end

init(logging)

logging.__index = logging

function logging.new()
	return init(setmetatable({}, logging))
end

if not ... then

	local sock = require'sock'

	local logging = logging.new()

	sock.resume(sock.thread(function()
		sock.sleep(5)
		logging:toserver_stop()
		print'told to stop'
	end))

	sock.run(function()

		logging.debug = true

		logging:tofile('test.log', 64000)
		logging:toserver('127.0.0.1', 1234, 998, .5)

		for i=1,1000 do
			logging.note('test-m', 'test-ev', 'foo %d bar', i)
		end

		local sock = require'sock'
		local fs = require'fs'

		local s1 = sock.tcp()
		local s2 = sock.tcp()
		local t1 = coroutine.create(function() end)
		local t2 = coroutine.create(function() end)

		logging.dbg('test-m', 'test-ev', '%s %s %s %s\nanother thing', s1, s2, t1, t2)

	end)

end

return logging
