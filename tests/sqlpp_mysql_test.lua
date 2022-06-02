
require'sock'
require'logging'
require'sqlpp'

local spp = sqlpp'mysql'

if false then
	pr(spp.query(outdent[[
		select
			{verbatim}, '?', :foo, ::bar,
		from
		#if false
			no see
		#else
			see
		#endif
	]], {
		verbatim = 'can be anything',
		foo = 'FOO',
		bar = 'BAR.BAZ',
	}, 'xxx'))
end

run(function()

	local cmd = spp.connect{
		host = '10.0.0.5',
		port = 3307,
		user = 'root',
		pass= 'root',
		db = 'sp',
		charset = 'utf8mb4',
	}

	if false then
		pr(cmd:table_def'usr')
	end

	if false then
		pr(cmd:query'select * from val limit 1; select * from attr limit 1')
	end

	if false then
		local stmt = assert(cmd:prepare('select * from val where val = :val'))
		pr(stmt:exec{val = 2})
	end

	if false then
		pr(cmd:query'insert into val (val, attr) values (100000000, 10000000)')
	end

	if false then
		pr(cmd:query'delete from val where val = 1')
	end

	if false then
		cmd:insert_rows('val',
			{{note1 = 'x', val1 = 'y'}},
			{note = 'note1', val = 'val1'}
		)
	end

	if false then
		pr(cmd:table_defs()['sp.currency'])
	end

	if false then

		local cn = spp.connect{
			host = '10.0.0.5',
			port = 3307,
			user = 'root',
			pass = 'root',
			db = 'sp',
			charset = 'utf8mb4',
		}

		cn.schemas.sp = cn:extract_schema()

		local function pr(cols, h)
			local t = {}
			for _,k in ipairs(h) do
				add(t, fmt('%20s', k))
			end
			print(cat(t))
			print()
			for _,col in ipairs(cols) do
				local t = {}
				for _,k in ipairs(h) do
					local v = col[k]
					v = isnum(v) and fmt('%0.17g', v) or v
					v = istab(v) and pp.format(v) or v
					add(t, fmt('%-20s', repl(v, nil, '')))
				end
				print(cat(t))
			end
			print()
		end

		local rows, cols = cn:query({get_table_defs=1}, 'select * from test')
		print()
		pr(cols, {
			'name',
			'mysql_type',
			'mysql_display_type',
			'size',
			'display_width',
			'mysql_charset',
			'mysql_collation',
			'type',
			'min',
			'max',
			'digits',
			'decimals',
			'has_time',
			'padded',
			'enum_values',
			'default',
			'mysql_default',
			'mysql_display_charset',
			'mysql_display_collation',
			'mysql_buffer_type',
		})

		pr(rows)

		cn:close()

	end

end)
