--[==[

	$ | daemon apps
	Written by Cosmin Apreutesei. Public Domain.

	daemon(app_name, cmdline_args...) -> app

	app.name       app name: the name of the Lua script without file extension.
	app.dir        app directory.
	app.bindir     app bin directory.
	app.vardir     r/w persistent data dir.
	app.tmpdir     r/w persistent temp dir.
	app.wwwdir     app www directory.
	app.libwwwdir  shared www directory.
	app.conf       options loaded from config file (see below).

	cmd_server     cmdline section for server control

	exit(app:run(...))    run the daemon app with cmdline args

	config(name[, default]) -> val

FILES

	APP.conf       config file loaded at start-up. its globals go in app.conf.
	---------------------------------------------------------------------------
	deploy         app deployment name.
	env            app environment ('dev').
	log_host       log server host.
	log_port       log server port.

]==]

require'$fs'
require'$log'
require'$cmd'
require'$sock'

local app = {}

--daemonize (Linux only) -----------------------------------------------------

cmd_server = cmdsection'SERVER CONTROL'

ffi.cdef[[
int setsid(void);
int fork(void);
unsigned int umask(unsigned int mask);
int close(int fd);
]]

local function findpid(pid, cmd)
	local s = load(_('/proc/%s/cmdline', pid), false, true)
	return s and s:find(cmd, 1, true) and true or false
end

local function running()
	local pid = tonumber((load(app.pidfile, false)))
	if not pid then return false end
	return findpid(pid, arg[0]), pid
end

cmd_server(Linux, 'running', 'Check if the server is running', function()
	return running() and 0 or 1
end)

cmd_server(Linux, 'status', 'Show server status', function()
	local is_running, pid = running()
	if is_running then
		say('Running. PID: %d', pid)
	else
		say 'Not running.'
		rm(app.pidfile)
	end
end)

local run_server
cmd_server('run', 'Run server in foreground', function()
	run_server()
end)

cmd_server(Linux, 'start', 'Start the server', function()
	local is_running, pid = running()
	if is_running then
		say('Already running. PID: %d', pid)
		return 1
	elseif pid then
		say'Stale pid file found.'
	end
	local pid = C.fork()
	assert(pid >= 0)
	if pid > 0 then --parent process
		save(app.pidfile, tostring(pid))
		say('Started. PID: %d', pid)
		os.exit(0)
	else --child process
		C.umask(0)
		local sid = C.setsid() --prevent killing the child when parent is killed.
		assert(sid >= 0)
		logging.quiet = true
		io.stdin:close()
		io.stdout:close()
		io.stderr:close()
		C.close(0)
		C.close(1)
		C.close(2)
		local ok = pcall(run_server)
		rm(app.pidfile)
		os.exit(ok and 0 or 1)
	end
end)

cmd_server(Linux, 'stop', 'Stop the server', function()
	local is_running, pid = running()
	if not is_running then
		say'Not running.'
		return 1
	end
	sayn('Killing PID %d...', pid)
	exec('kill %d', pid)
	for i=1,10 do
		if not running() then
			say'OK.'
			rm(app.pidfile)
			return 0
		end
		sayn'.'
		sleep(.1)
	end
	say'Failed.'
	return 1
end)

cmd_server(Linux, 'restart', 'Restart the server', function()
	if cmd_server.stop.fn() == 0 then
		cmd_server.start.fn()
	end
end)

cmd_server('tail', 'tail -f the log file', function()
	exec('tail -f %s', app.logfile)
end)

--init -----------------------------------------------------------------------

function daemon(app_name, ...)

	local cmd_name, cmd_args, cmd_fn = cmdaction(...) --process cmdline options.

	assert(not app.name, 'daemon() already called')

	randomseed(clock()) --mainly for resolver.

	--non-configurable, convention-based things.
	app.name      = assert(app_name, 'app name required')
	app.dir       = fs.scriptdir()
	app.startdir  = fs.startcwd()
	app.bindir    = indir(app.dir, 'bin', win and 'windows' or 'linux')
	app.vardir    = indir(app.dir, 'var')
	app.tmpdir    = indir(app.dir, 'tmp')
	app.wwwdir    = indir(app.dir, 'www')
	app.libwwwdir = indir(app.dir, 'sdk', 'www')

	app.pidfile   = indir(app.dir, app.name..'.pid')
	app.logfile   = indir(app.dir, app.name..'.log')
	app.conffile  = indir(app.dir, app.name..'.conf')

	--consider this module loaded so that other app submodules that
	--require it at runtime don't try to load it again.
	package.loaded[app.name] = app

	--make require() see Lua modules from the app dir.
	glue.luapath(app.dir)

	--cd to app.dir so that we can use relative paths for everything if we want to.
	chdir(app.dir)
	function fs.chdir(dir)
		error'chdir() not allowed'
	end

	--load an optional config file.
	do
		local conf_s = load(app.conffile, false)
		app.conf = {}
		if conf_s then
			local conf_fn = assert(loadstring(conf_s))
			setfenv(conf_fn, app.conf)
			conf_fn()
		end
	end

	--set up logging.
	logging.deploy  = app.conf.deploy
	logging.env     = app.conf.env

	local start_heartbeat, stop_heartbeat do
		local stop, sleeper
		function start_heartbeat()
			resume(thread(function()
				sleeper = sleep_job(1)
				while not stop do
					logging.logvar('live', time())
					sleeper:sleep(1)
				end
			end, 'logging-heartbeat'))
		end
		function stop_heartbeat()
			stop = true
			if sleeper then
				sleeper:wakeup()
			end
		end
	end

	function run_server() --fw. declared.
		app.server_running = true
		setenv('TZ', ':/etc/localtime', 0)
		--^^avoid having os.date() stat /etc/localtime.
		logging:tofile(app.logfile)
		logging.flush = logging.debug
		local logtoserver = app.conf.log_host and app.conf.log_port
		if logtoserver then
			logging:toserver(app.conf.log_host, app.conf.log_port)
			start_heartbeat()
		end
		app:run_server()
		if logtoserver then
			stop_heartbeat()
			logging:toserver_stop()
		end
		logging:tofile_stop()
	end

	function app:run_cmd(cmd_name, cmd_fn, ...) --stub
		return cmd_fn(cmd_name, ...)
	end

	function app:run()
		if cmd_name == app.name then --caller module loaded with require()
			return app
		end
		return self:run_cmd(cmd_name, cmd_fn, unpack(cmd_args))
	end

	return app

end
