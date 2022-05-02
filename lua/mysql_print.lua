
--MySQL result pretty printing.
--Written by Cosmin Apreutesei. Public Domain.

local glue = require'glue'
local cjson = require'cjson'
local null = cjson.null
local cat = table.concat
local index = glue.index

local function ellipsis(s,n)
	return #s > n and (s:sub(1,n-3) .. '...') or s
end

local align = {}

function align.left(s,n)
	s = s..(' '):rep(n - #s)
	return ellipsis(s,n)
end

function align.right(s,n)
	s = (' '):rep(n - #s)..s
	return ellipsis(s,n)
end

function align.center(s,n)
	local total = n - #s
	local left = math.floor(total / 2)
	local right = math.ceil(total / 2)
	s = (' '):rep(left)..s..(' '):rep(right)
	return ellipsis(s,n)
end

local function fit(s,n,al)
	return align[al or 'left'](s,n)
end

local function print_table(opt)
	local rows    = opt.rows
	local cols    = opt.cols
	local aligns  = opt.aligns
	local minsize = opt.minsize or 0
	local sumdefs = opt.sums
	local print   = opt.print or _G.print

	local max_sizes = {}
	for j=1,#cols do
		max_sizes[j] = math.max(max_sizes[j] or minsize,
			#cols[j], sd and #sd[1] or 0, sd and #sd[2] or 0)
	end
	for j=1,#cols do
		for i=1,#rows do
			max_sizes[j] = math.max(max_sizes[j], #rows[i][j])
		end
	end

	local function fits(j, s)
		return fit(s, max_sizes[j], aligns and aligns[j]) .. ' | '
	end

	local function hr(j)
		return ('-'):rep(max_sizes[j]) .. ' + '
	end

	print()
	local t, p = {}, {}
	for j=1,#cols do
		t[j] = fits(j, cols[j])
		p[j] = hr(j)
	end
	print(cat(t))
	print(cat(p))

	local t = {}
	for i=1,#rows do
		local s = ''
		for j=1,#cols do
			t[j] = fits(j, rows[i][j])
		end
		print(cat(t))
	end

	if sumdefs then
		local sums, sumops, p = {}, {}, {}
		for j=1,#cols do
			local sd = sumdefs[cols[j]]
			p[j] = hr(j)
			sumops[j] = fits(j, sd and sd[1] or '')
			sums  [j] = fits(j, sd and sd[2] or '')
		end
		print(cat(p))
		print(cat(sumops))
		print(cat(sums))
		print(cat(p))
	end

	print()
end

local function format_cell(v, field, null_s)
	if v == null or v == nil then
		return null_s
	elseif field.to_text then
		return field.to_text(v, field)
	else
		return tostring(v)
	end
end

local function cell_align(current_align, cell_value, field)
	if field and field.align then return field.align end
	if current_align == 'left' then return 'left' end
	if type(cell_value) == 'number' or type(cell_value) == 'cdata' then return 'right' end
	return 'left'
end

function print_result(opt)
	local rows    = opt.rows
	local fields  = opt.fields
	local minsize = opt.minsize
	local sums    = opt.sums
	local null_s  = opt.null_text or ''
	local hidecols = opt.hidecols and index(words(opt.hidecols))
	local showcols = opt.showcols and index(words(opt.showcols))

	local colmap
	if showcols then
		colmap = {}
		for s in pairs(showcols) do
			if s:find'=' then
				local col, head = s:match'(.-)=(.*)'
				showcols[s] = nil
				showcols[col] = true
				colmap[col] = head
			end
		end
	end

	local valindex
	if hidecols or showcols then

		valindex = {}
		local fields0 = fields
		fields = {}
		for i,field in ipairs(fields0) do
			local col = field.name
			if (not hidecols or not hidecols[col]) and (not showcols or showcols[col]) then
				fields[#fields+1] = field
				valindex[#fields] = i
			end
		end
	end

	local cols = {}
	local colindex = {}
	for i, field in ipairs(fields) do
		cols[i] = colmap and colmap[field.name] or field.name
		colindex[field.name] = i
	end

	local textrows = {}
	local aligns = {}
	for i,row in ipairs(rows) do
		local t = {}
		for j=1,#cols do
			local vj = valindex and valindex[j] or j
			t[j] = format_cell(row[vj], fields[j], null_s)
			aligns[j] = cell_align(aligns[j], row[vj], fields[j])
		end
		textrows[i] = t
	end

	local sumdefs
	if opt.sums then
		sumdefs = {}
		local function to_number(s) return tonumber(s) end
		local function from_number(n) return tostring(n) end
		for col, op in pairs(opt.sums) do
			local n
			local j = colindex[col]
			local field = fields[j]
			if not field then error('sum col not found: '..col) end
			local to_number   = field.to_number   or to_number
			local from_number = field.from_number or from_number
			for i,row in ipairs(rows) do
				local vj = valindex and valindex[j] or j
				local v = row[vj]
				if v ~= nil then
					local x = to_number(v, field)
					if op == 'sum' or op == 'avg' then
						n = (n or 0) + x
					elseif op == 'min' then
						n = math.min(n or 1/0, x)
					elseif op == 'max' then
						n = math.max(n or -1/0, x)
					end
				end
			end
			local v
			if n then
				if op == 'avg' then
					n = n / #rows
				end
				v = from_number(n, field)
			end
			sumdefs[col] = {op, format_cell(v, field, null_s)}
		end
	end

	print_table{
		rows = textrows, cols = cols, aligns = aligns, valindex = valindex,
		minsize = minsize, sums = sumdefs, print = opt.print,
	}
end

return {
	fit = fit,
	format_cell = format_cell,
	cell_align = cell_align,
	table = print_table,
	result = print_result,
}
