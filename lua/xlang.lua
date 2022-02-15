--[==[

	webb | xapp language/country/currency setting UI
	Written by Cosmin Apreutesei. Public Domain.

ROWSETS

	S                  used by translation UIs
	lang               used by the language chooser

]==]

require'webb_lang'
require'webb_spa'
require'xrowset_sql'

Sfile'xlang.lua'

local text_in_english          = Sf('text_in_english', 'Text in English')
local text_in_current_language = Sf('text_in_current_language', 'Text in Current Language')

--S translation rowset -------------------------------------------------------

rowset.S = virtual_rowset(function(self, ...)

	self.allow = 'admin'

	self.fields = {
		{name = 'ext'},
		{name = 'id'},
		{name = 'en_text', text = text_in_english},
		{name = 'text', text = text_in_current_language},
		{name = 'files'},
		{name = 'occurences', type = 'number', max_w = 30},
	}
	self.pk = 'ext id'
	self.cols = 'id en_text text'
	function self:load_rows(rs, params)
		rs.rows = {}
		local lang = lang()
		for ext_id, t in pairs(Sfile_ids()) do
			local ext, id = ext_id:match'^(.-):(.*)$'
			local s = S_texts(lang, ext)[id]
			add(rs.rows, {ext, id, t.en_s, s, t.files, t.n})
		end
	end

	local function update_key(vals)
		local ext  = checkarg(json_str_arg(vals['ext:old']))
		local id   = checkarg(json_str_arg(vals['id:old']))
		local lang = checkarg(json_str_arg(vals['param:lang']))
		return ext, id, lang
	end

	function self:update_row(vals)
		local ext, id, lang = update_key(vals)
		local text = json_str_arg(vals.text)
		update_S_texts(lang, ext, {[id] = text or false})
	end

	function self:load_row(vals)
		local ext, id, lang = update_key(vals)
		local t = Sfile_ids()[ext..':'..id]
		if not t then return end
		local s = S_texts(lang, ext)[id]
		return {ext, id, t.en_s, s, t.files, t.n}
	end

end)

--S_schema_fields translation rowset -----------------------------------------

local function S_schema_file(lang, attr)
	return varpath(string.format('%s-s-%s-col-%s.lua', config'app_name', lang, attr))
end

--TODO: invalidate this cache based on file's mtime but don't check too often.
local function S_schema_texts(lang, attr)
	local f = loadfile(S_schema_file(lang, attr))
	return f and f() or {}
end

local function save_S_schema_texts(lang, attr, t)
	save(S_schema_file(lang, attr), 'return '..pp.format(t, '\t'))
end

local valid_attrs

rowset.S_schema_attrs = virtual_rowset(function(self, ...)

	self.allow = 'admin'

	self.fields = {
		{name = 'attr', },
		{name = 'info', hidden = true},
	}
	self.pk = 'attr'

	local rows = {
		{'text', Sf('field_attr_info_text', 'The name of field as it appears in grid headers')},
		{'info', Sf('field_attr_info_info', 'The long description of the field')},
	}
	function self:load_rows(rs)
		rs.rows = {}
		for i,row in ipairs(rows) do
			rs.rows[i] = {row[1], row[2]()}
		end
	end

	valid_attrs = glue.imap(rows, 1)
	update(valid_attrs, glue.index(valid_attrs))

end)

local function db_schema()
	return config('db_schema')
end

rowset.S_schema_fields = virtual_rowset(function(self, ...)

	self.allow = 'admin'

	self.fields = {
		{name = 'table'},
		{name = 'col', text = 'Column'},
		{name = 'attr'},
		{name = 'en_text', text = text_in_english},
		{name = 'text', text = text_in_current_language},
	}

	self.pk = 'table col attr'
	self.cols = 'table col en_text text'
	function self:load_rows(rs, params)
		local attrs = params['param:filter']
		rs.rows = {}
		for i,attr in ipairs(attrs) do
			local texts = S_schema_texts(lang(), attr)
			for tbl_name, tbl in glue.sortedpairs(db_schema().tables) do
				for i, fld in ipairs(tbl.fields) do
					local en_text = fld['en_'..attr]
					if type(en_text) == 'function' then --getter/generator
						en_text = en_text()
					end
					local text = texts[tbl_name..'.'..fld.col]
					table.insert(rs.rows, {tbl_name, fld.col, attr, en_text, text})
				end
			end
		end
	end

	local function checkargs(vals)
		local tbl  = checkarg(str_arg(vals['table:old']))
		local col  = checkarg(str_arg(vals['col:old']))
		local attr = checkarg(str_arg(vals['attr:old']))
		local text = str_arg(vals['text'])
		assert(valid_attrs[attr])
		local en_text = db_schema().tables[tbl].fields[col][attr]
		return tbl, col, attr, text, en_text
	end

	function self:update_row(vals)
		local tbl, col, attr, text = checkargs(vals)
		local texts = S_schema_texts(lang(), attr)
		texts[tbl..'.'..col] = text
		save_S_schema_texts(lang(), attr, texts)
	end

	function self:load_row(vals)
		local tbl, col, attr, text, en_text = checkargs(vals)
		local texts = S_schema_texts(lang(), attr)
		return {tbl, col, attr, en_text, text}
	end

end)

local function S_col(tbl_col, attr)
	local texts = S_schema_texts(lang(), attr)
	return texts[tbl_col]
end

function update_S_schema_texts()
	local sc = db_schema()
	for _,attr in ipairs(valid_attrs) do
		for tbl_name, tbl in glue.sortedpairs(db_schema().tables) do
			for _,fld in ipairs(tbl.fields) do
				local en_text = fld[attr]
				fld['en_'..attr] = en_text
				local tbl_col = tbl_name..'.'..fld.col
				fld[attr] = function()
					local s = S_col(tbl_col, attr)
					if s then
						return s
					end
					s = en_text
					if type(s) == 'function' then
						s = s()
					end
					return s
				end
			end
		end
	end
end

--lang picker rowset ---------------------------------------------------------

rowset.lang = sql_rowset{
	select = [[
		select
			lang,
			en_name,
			name,
			supported
		from lang
	]],
	pk = 'lang',
	field_attrs = {
		lang = {w = 40},
	},
}

rowset.pick_lang = sql_rowset{
	select = [[
		select
			lang,
			name,
			en_name
		from lang
	]],
	where_all = 'supported = 1',
	pk = 'lang',
}
