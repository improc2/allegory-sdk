local expat = require'expat'
local pp = require'pp'

local callbacks = setmetatable({}, {__index = function(t,k) return function(...) print(k,...) end end})
expat.parse({path='../c/expat/src/expat/doc/xmlwf.xml'}, callbacks)
pp(expat.treeparse{path='../c/expat/src/expat/doc/xmlwf.xml'})

function soaptest(xmlsrc)
	local xmlsoap = expat.treeparse({
		namespacesep = '|',
		string = xmlsrc})
	print('tag = '..pp.format(xmlsoap
		.tags['http://schemas.xmlsoap.org/soap/envelope/|Envelope']
		.tags['http://schemas.xmlsoap.org/soap/envelope/|Body']
		.children[1]
		.tag))
	for k,v in pairs(xmlsoap
			.tags['http://schemas.xmlsoap.org/soap/envelope/|Envelope']
			.tags['http://schemas.xmlsoap.org/soap/envelope/|Body']
			.children[1]
			.tags) do
		print(k..' = '..pp.format(v.cdata))
	end
	print''
end

--[[Both testcases below should generate the same output:
tag = 'http://test.soap.service.luapower.com/|serviceA'
paramB = 'SOME STUFF'
paramC = '123'
paramA = nil
]]--

-- Envelope generated by Python Suds 0.4.1
soaptest[[<?xml version="1.0" encoding="UTF-8"?>
	<SOAP-ENV:Envelope xmlns:SOAP-ENC="http://schemas.xmlsoap.org/soap/encoding/"
			xmlns:ns0="http://schemas.xmlsoap.org/soap/encoding/"
			xmlns:ns1="http://test.soap.service.luapower.com/"
			xmlns:ns2="http://schemas.xmlsoap.org/soap/envelope/"
			xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
			xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"
			SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
		<SOAP-ENV:Header/>
		<ns2:Body>
			<ns1:serviceA>
				<paramA></paramA>
				<paramB>SOME STUFF</paramB>
				<paramC>123</paramC>
			</ns1:serviceA>
		</ns2:Body>
	</SOAP-ENV:Envelope>]]

-- Envelope generated by Apache CXF 2.7.1
soaptest[[<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
		<soap:Body>
			<ns1:serviceA xmlns:ns1="http://test.soap.service.luapower.com/">
				<paramA></paramA>
				<paramB>SOME STUFF</paramB>
				<paramC>123</paramC>
			</ns1:serviceA>
		</soap:Body>
	</soap:Envelope>]]
