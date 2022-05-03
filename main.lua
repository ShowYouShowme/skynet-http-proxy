local skynet = require "skynet"
local socket = require "skynet.socket"
local dns    = require "skynet.dns"

-- 测试命令 curl -x 127.0.0.1:8001 http://www.baidu.com/

-- 测试post请求 curl -x 127.0.0.1:8001 -H "Content-Type: application/json" -X POST -d '{"user_id": "123", "coin":100, "success":1, "msg":"OK!" }' "http://www.baidu.com/"

local function parse(first_line)
	for method, url, version in string.gmatch(first_line, '(.+) (.+) (.+)') do
		-- skynet.error(string.format('method:%s,url:%s,version:%s', method,url,version))
		local start = string.find(url, "//", 1)
		start = start + 2
		local last =  string.find(url, "/", start)
		local host = string.sub(url,start, last-1)
		return host
		-- for schema, host, path in string.gmatch(url, '(.+)://(.+)/(.*)') do
		-- 	-- skynet.error(string.format('schema:%s,host:%s,path:%s', schema,host,path))
		-- 	-- TODO port 需要处理
		-- 	return method, schema, host
		-- end
	end
	return nil
end

local function tunnel(from, to, name, msg)
	-- skynet.error('name=', name)
	if msg then
		socket.write(to, msg)
	end
	while true do
		local ok, data = pcall(socket.read, from)
		if not ok then
			skynet.error("发生错误,关闭链接:"..data)
			socket.close(from)
			socket.close(to)
			return
		end
		if not data then
			-- EOF
			-- skynet.error("对端主动关闭链接")
			socket.close(from)
			socket.close(to)
			return
		else
			socket.write(to, data)
		end
	end
end

local function is_complete_header(buf)
	local first, last = string.find(buf, '\r\n\r\n')
	return first ~= nil
end

local function parse_method(line)
	for method, url, version in string.gmatch(line, '(.+) (.+) (.+)') do
		return method
	end
	error('http 首行解析错误!')
end

-- 注意为IP地址的情况 TODO
local function parst_host_and_port(line)
	for method, url, version in string.gmatch(line, '(.+) (.+) (.+)') do
		for host, port in string.gmatch(url, '(.+):(.+)') do
			return host, port
		end
	end
	error('https connect 解析host 和 port 出错')
end

local function is_ip_address(str)
	for p1, p2, p3, p4 in string.gmatch(str, '([0-9]+).([0-9]+).([0-9]+).([0-9]+)') do
		-- skynet.error('p1:', p1, " p2:", p2, " p3:", p3, " p4:", p4)
		return true
	end
	return false
end

-- TODO 这个函数把body 和 header解析出来
local function parse_header_and_body(str)
	-- skynet.error("str:", str)
	local header_end, _ = string.find(str, '\r\n\r\n')
	if header_end then
		local first, _ = string.find(str, '\r\n')
		local first_line = string.sub(str, 1, first - 1)
		local method = parse_method(first_line)
		if method == 'POST' then
			-- skynet.error(str)
			local ii, idx       = string.find(str, 'Content%-Length:')
			local i, header_len = string.find(str, '\r\n\r\n')
			skynet.error(ii, idx, i)
			if idx then
				local payload_len = tonumber(string.sub(str, idx + 1, i - 1))
				-- skynet.error("payload_len : ", payload_len)
				if #str - header_len ~= payload_len then
					-- skynet.error('POST 数据包不完整')
					return nil, nil
				else
					return string.sub(str, 1, header_end - 1), string.sub(str, header_len + 1)
				end
			end
		else
			return string.sub(str, 1, header_end - 1), nil
		end
	else
		return nil, nil
	end
end

--简单echo服务
local function echo(cID, addr)
	socket.start(cID)
	local buf = ''
	while true do -- TODO 如何确保数据包已经接收完整
		local str = socket.read(cID)
		if str then
			buf = buf .. str
			-- skynet.error("[buf] " .. buf)
			local first, last = string.find(buf, '\r\n')
			local header,body = parse_header_and_body(buf)
			-- skynet.error('header:', header, " body:", body)
			if header then
				local first_line = string.sub(buf, 1, first - 1)
				local method = parse_method(first_line)
				if method == 'CONNECT' then
					local host, port = parst_host_and_port(first_line)
					-- skynet.error("host : ", host)
					if not is_ip_address(host) then
						local ok
						local _host = host
						ok, host = pcall(dns.resolve, host)
						if not ok then
							socket.close(cID)
							skynet.error('[ERROR]:DNS查询失败 域名:',_host)
							return
						end
					end
					local addr = host .. ":" .. tostring(port)
					-- skynet.error('addr:', addr)
					local id = socket.open(addr)
					if not id then
						socket.close(cID)
						skynet.error('[ERROR]:建立链接失败 addr:',addr)
						return
					end
					socket.write(cID, 'HTTP/1.1 200 Connection Established\r\n\r\n')

					local from = cID
					local to = id
					-- 写入数据
					skynet.fork(tunnel, from, to, 'client')
					skynet.fork(tunnel, to, from, 'server')
					return
				end

				-- TODO 这里用自己的http服务测试post请求
				-- TODO 注意IP地址和端口的情况
				skynet.error(first_line) --[first, last]
				if method == 'GET' or method == 'POST' then
					local host = parse(first_line)
					-- skynet.error(string.format("method:%s,schema:%s,host:%s",method,schema,host))
					local port = 80 -- TODO 有的时候不是80

					-- 发起链接
					skynet.error('host:', host)
					local ip = dns.resolve(host)
					ip = ip .. ":" .. tostring(port)
					-- skynet.error("ip : ", ip, " type : ", type(ip))

					-- skynet.error("connect ".. ip)
					local id = socket.open(ip)
					assert(id)
					local from = cID
					local to = id
					-- 写入数据
					--socket.write(id, buf)
					skynet.fork(tunnel, cID, id,"client", buf)
					skynet.fork(tunnel, id, cID, "server")
					return
				end

				skynet.error('[ERROR]:不支持的方法:'..method)
				socket.close(cID)
				skynet.error(addr .. " disconnect")
				return
			end
		else
			socket.close(cID)
			skynet.error(addr .. " disconnect")
			return
		end
	end
end

local function accept(cID, addr)
	-- skynet.error(addr .. " accepted")
	skynet.fork(echo, cID, addr) --来一个链接，就开一个新的协程来处理客户端数据
end

--服务入口
skynet.start(function()
	dns.server()
	local addr = "0.0.0.0:8001"
	skynet.error("listen " .. addr)
	local lID = socket.listen(addr)
	assert(lID)
	socket.start(lID, accept)
end)
