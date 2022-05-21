--[=[

	HTTP 1.1 coroutine-based async server (based on sock.lua, sock_libtls.lua).
	Written by Cosmin Apreutesei. Public Domain.

	Features, https, gzip compression, persistent connections, pipelining,
	resource limits, multi-level debugging, cdata-buffer-based I/O.

server:new(opt) -> server   | Create a server object

	libs            required: pass 'sock sock_libtls zlib'
	listen          {host=, port=, tls=t|f, tls_options=}
	tls_options     options to pass to sock_libtls.

]=]

if not ... then require'http_server_test'; return end

local http = require'http'
local time = require'time'
local glue = require'glue'
local errors = require'errors'

local _ = string.format
local attr = glue.attr
local push = table.insert

local server = {
	libs = 'sock fs zlib sock_libtls',
	type = 'http_server', http = http,
	tls_options = {
		protocols = 'tlsv1.2',
		ciphers = [[
			ECDHE-ECDSA-AES256-GCM-SHA384
			ECDHE-RSA-AES256-GCM-SHA384
			ECDHE-ECDSA-CHACHA20-POLY1305
			ECDHE-RSA-CHACHA20-POLY1305
			ECDHE-ECDSA-AES128-GCM-SHA256
			ECDHE-RSA-AES128-GCM-SHA256
			ECDHE-ECDSA-AES256-SHA384
			ECDHE-RSA-AES256-SHA384
			ECDHE-ECDSA-AES128-SHA256
			ECDHE-RSA-AES128-SHA256
		]],
		prefer_ciphers_server = true,
	},
}

function server:bind_libs(libs)
	for lib in libs:gmatch'[^%s]+' do
		if lib == 'sock' then
			local sock = require'sock'
			self.tcp           = sock.tcp
			self.thread        = sock.thread
			self.resume        = sock.resume
			self.cowrap        = sock.cowrap
			self.threadstatus  = sock.threadstatus
			self.start         = sock.start
			self.sleep         = sock.sleep
			self.currentthread = sock.currentthread
			self.liveadd       = sock.liveadd
		elseif lib == 'sock_libtls' then
			local socktls = require'sock_libtls'
			self.stcp          = socktls.server_stcp
		elseif lib == 'zlib' then
			self.http.zlib = require'zlib'
		elseif lib == 'fs' then
			self.loadfile = require'fs'.load
			self.tls_options.loadfile = self.loadfile
		else
			assert(false)
		end
	end
end

function server:time(ts)
	return glue.time(ts)
end

function server:log(tcp, severity, module, event, fmt, ...)
	local logging = self.logging
	if not logging or logging.filter[severity] then return end
	local s = type(fmt) == 'string' and _(fmt, logging.args(...)) or fmt or ''
	logging.log(severity, module, event, '%-4s %s', tcp, s)
end

function server:check(tcp, ret, ...)
	if ret then return ret end
	self:log(tcp, 'ERROR', 'htsrv', ...)
end

function server:new(t)

	local self = glue.object(self, {}, t)

	if self.libs then
		self:bind_libs(self.libs)
	end

	if self.debug and (self.logging == nil or self.logging == true) then
		self.logging = require'logging'
	end

	local function req_onfinish(req, f)
		glue.after(req, 'finish', f)
	end

	local function handler(stcp, ctcp, listen_opt)

		local http = self.http:new({
			debug = self.debug,
			max_line_size = self.max_line_size,
			tcp = ctcp,
			cowrap = self.cowrap,
			currentthread = self.currentthread,
			threadstatus = self.threadstatus,
			listen_options = listen_opt,
		})

		while not ctcp:closed() do

			local req = assert(http:read_request())

			local out, out_thread, send_started, send_finished

			local function send_response(opt)
				send_started = true
				local res = http:build_response(req, opt, self:time())
				assert(http:send_response(res))
				send_finished = true
			end

			--NOTE: both req:respond() and out() raise on I/O errors breaking
			--user's code, so use req:onfinish() to free resources.
			function req.respond(req, opt)
				if opt.want_out_function then
					out, out_thread = self.cowrap(function(yield)
						opt.content = yield
						send_response(opt)
					end, 'http-server-out %s %s', ctcp, req.uri)
					out()
					return out
				else
					send_response(opt)
				end
			end

			req.thread = self.currentthread()

			req.onfinish = req_onfinish

			local ok, err = errors.pcall(self.respond, req)
			if req.finish then
				req:finish()
			end

			if not ok then
				if not send_started then
					if errors.is(err, 'http_response') then
						req:respond(err)
					else
						self:check(ctcp, false, 'respond', '%s', err)
						req:respond{status = 500}
					end
				else --status line already sent, too late to send HTTP 500.
					if out_thread and self.threadstatus(out_thread) ~= 'dead' then
						--Signal eof so that the out() thread finishes. We could
						--abandon the thread and it will be collected without leaks
						--but we want it to be removed from logging.live immediately.
						--NOTE: we're checking that out_thread is really suspended
						--because we also get here on I/O errors which kill it.
						out()
					end
					error(err)
				end
			elseif not send_finished then
				if out then --out() thread waiting for eof
					out() --signal eof
				else --respond() not called
					send_response{}
				end
			end

			--the request must be entirely read before we can read the next request.
			if req.body_was_read == nil then
				req:read_body()
			end
			assert(req.body_was_read, 'request body was not read')

		end
	end

	local stop
	function self:stop()
		stop = true
	end

	self.sockets = {}

	assert(self.listen and #self.listen > 0, 'listen option is missing or empty')

	for i,t in ipairs(self.listen) do
		if t.addr == false then
			goto continue
		end

		local tcp = assert(self.tcp())
		assert(tcp:setopt('reuseaddr', true))
		local addr, port = t.addr or '*', t.port or (t.tls and 443 or 80)

		local ok, err = tcp:listen(addr, port)
		if not ok then
			self:check(tcp, false, 'listen', '("%s", %s): %s', addr, port, err)
			goto continue
		end

		local tls = t.tls
		if tls then
			local opt = glue.update(self.tls_options, t.tls_options)
			local stcp, err = self.stcp(tcp, opt)
			if not self:check(tcp, stcp, 'stcp', '%s', err) then
				tcp:close()
				goto continue
			end
			tcp = stcp
		end
		self.liveadd(tcp, tls and 'https' or 'http')
		push(self.sockets, tcp)

		function accept_connection()
			local ctcp, err, retry = tcp:accept()
			if not self:check(tcp, ctcp, 'accept', '%s', err) then
				if retry then
					--temporary network error. let it retry but pause a little
					--to avoid killing the CPU while the error persists.
					sleep(.2)
				else
					self:stop()
				end
				return
			end
			self.liveadd(ctcp, tls and 'https' or 'http')
			self.resume(self.thread(function()
				local ok, err = errors.pcall(handler, tcp, ctcp, t)
				self:check(ctcp, ok or errors.is(err, 'tcp'), 'handler', '%s', err)
				ctcp:close()
			end, 'http-server-client %s', ctcp))
		end

		self.resume(self.thread(function()
			while not stop do
				accept_connection()
			end
		end, 'http-listen %s', tcp))

		::continue::
	end

	return self
end

return server
