--[==[

	webb | single-page apps
	Written by Cosmin Apreutesei. Public Domain.

API

	client_config(name, [default])         make config value available on client-side
	cssfile(file)                          add one or more css files to all.css
	jsfile(file)                           add one or more js files to all.js
	fontfile(file)                         add one or more font files to the preload list
	css(s)                                 add css code to inline.css
	js(s)                                  add js code to inline.js
	html(s)                                add inline html code to the SPA body

ACTIONS

	config.js        expose required config() values
	strings.js       load strings.<lang>.js
	all.js           output of jsfile() calls
	all.css          output of cssfile() calls
	inline.js        output of js() calls
	inline.css       output of css() calls
	404.html         SPA response

LOADS

	glue, divs, webb_spa, purify, mustache

CONFIG

	js_mode             'separate'   'bundle' | 'ref' | 'separate'
	css_mode            'separate'   'bundle' | 'ref' | 'separate'

	body_classes                     css classes for <body>
	body_attrs                       attributes for <body>
	head                             content for <head>
	page_title_suffix                title suffix, both client-side & server-side
	infer_page_title                 server-side page title inferring f(body) -> s
	favicon_href                     favicon url
	client_action       true         enable client routing.
	aliases                          aliases for client-side routing; defined in webb_action.

	facebook_app_id                  for webb.auth.facebook.js
	google_client_id                 for webb.auth.google.js
	analytics_ua                     for webb.analytics.js

]==]

require'webb_action'

local format = string.format

local client_configs = {}

function client_config(name, default)
	if not client_configs[name] then
		client_configs[name] = true
		table.insert(client_configs, name)
	end
	return config(name, default)
end

client_config'app_name'
client_config'default_lang'
client_config'aliases'
client_config'root_action'
client_config'templates_action'
client_config'page_title_suffix'
client_config'session_cookie_name'
client_config'facebook_app_id'
client_config'analytics_ua'
client_config'google_client_id'

--pass required config values to the client
action['config.js'] = function()

	local cjson = require'cjson'

	--required config values must be initialized.
	--NOTE: these must match the real defaults that are set in their places of usage.
	config('default_lang', 'en')
	config('root_action', 'en')
	config('page_title_suffix', ' - '..host())
	config('session_cookie_name', 'session')

	for i,k in ipairs(client_configs) do
		local v = config(k)
		if v ~= nil then
			out(format('config(%s, %s)\n', json(k), json(v)))
		end
	end

end

action['strings.js'] = function()
	local t = S_texts(lang(), 'js')
	if not next(t) then return end
	out'assign(S_texts, '; out_json(t); out')'
end

--simple API to add js and css snippets and files from server-side code

local function sepbuffer(sep)
	local buf = stringbuffer()
	return function(s, sz)
		if s then
			buf(s, sz)
			buf(sep)
		else
			return buf()
		end
	end
end

cssfile = sepbuffer'\n'
wwwfile['all.css.cat'] = function()
	return cssfile() .. ' inline.css' --append inline code at the end
end

jsfile = sepbuffer'\n'
wwwfile['all.js.cat'] = function()
	return jsfile() .. ' inline.js' --append inline code at the end
end

local fontfiles = {}
function fontfile(file)
	for file in file:gmatch'[^%s]+' do
		table.insert(fontfiles, file)
	end
end

css = sepbuffer'\n'
wwwfile['inline.css'] = function()
	return css()
end

js = sepbuffer';\n'
wwwfile['inline.js'] = function()
	return js()
end

html = sepbuffer'\n'

cssfile[[
divs.css
]]

jsfile[[
glue.js
divs.js
webb_spa.js
config.js   // dynamic config
strings.js  // strings in current language
purify.js
mustache.js
]]

--format js and css refs as separate refs or as a single ref based on a .cat action.
--NOTE: with `embed` mode, urls in css files must be absolute paths!

local function jslist(cataction, mode)
	if mode == 'bundle' then
		out(format('	<script src="%s"></script>', href('/'..cataction)))
	elseif mode == 'embed' then
		out'<script>'
		outcatlist(cataction..'.cat')
		out'</script>\n'
	elseif mode == 'separate' then
		for i,file in ipairs(catlist_files(wwwfile(cataction..'.cat'))) do
			out(format('\t<script src="%s"></script>\n', href('/'..file)))
		end
	else
		assert(false)
	end
end

local function csslist(cataction, mode)
	if mode == 'bundle' then
		out(format('\t<link rel="stylesheet" type="text/css" href="/%s">', href(cataction)))
	elseif mode == 'embed' then
		out'<style>'
		outcatlist(cataction..'.cat')
		out'</style>\n'
	elseif mode == 'separate' then
		for i,file in ipairs(catlist_files(wwwfile(cataction..'.cat'))) do
			out(format('\t<link rel="stylesheet" type="text/css" href="%s">\n', href('/'..file)))
		end
	else
		assert(false)
	end
end

local function preloadlist()
	for i,file in ipairs(fontfiles) do
		out(format('\t<link rel="preload" href="%s" as="font" crossorigin>\n', href('/'..file)))
	end
end

--main template gluing it all together

local spa_template = [[
<!DOCTYPE html>
<html lang={{lang}} country={{country}}>
<head>
	<meta charset=utf-8>
	<title>{{title}}{{title_suffix}}</title>
	{{#favicon_href}}<link rel="icon" href="{{favicon_href}}">{{/favicon_href}}
{{{preload}}}
{{{all_css}}}
{{{all_js}}}
{{{head}}}
	{{{templates}}}
	<script>
		var client_action = {{client_action}}
	</{{undefined}}script>
</head>
<body {{body_attrs}} class="{{body_classes}}">
{{{body}}}
</body>
</html>
]]

local function page_title(infer, body)
	return infer and infer(body)
		--infer it from the name of the action
		or args(1):gsub('[-_]', ' ')
end

action['404.html'] = function(action)
	if _G.login then
		login() --sets lang from user profile.
	end
	local t = {}
	t.lang = lang()
	t.country = country()
	t.body = filter_lang(html(), lang())
	t.body_classes = config'body_classes'
	t.body_attrs = config'body_attrs'
	t.head = config'head'
	t.title = page_title(config'infer_page_title', t.body)
	t.title_suffix = config('page_title_suffix', ' - '..host())
	t.favicon_href = config'favicon_href'
	t.client_action = config('client_action', true)
	t.all_js  = record(jslist , 'all.js' , config('js_mode' , 'separate'))
	t.all_css = record(csslist, 'all.css', config('css_mode', 'separate'))
	t.preload = record(preloadlist)
	local buf = stringbuffer()
	for _,name in ipairs(template()) do
		buf(mustache_wrap(template(name), name))
	end
	t.templates = buf()
	out(render_string(spa_template, t))
end
