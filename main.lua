local skynet = require "skynet"
local socket = require "skynet.socket"
local dns    = require "skynet.dns"

-- 测试命令 curl -x 127.0.0.1:8001 http://www.baidu.com/

-- 测试post请求 curl -x 127.0.0.1:8001 -H "Content-Type: application/json" -X POST -d '{"user_id": "123", "coin":100, "success":1, "msg":"OK!" }' "http://www.baidu.com/"

local function parse(first_line)
	for method, url, version in string.gmatch(first_line, '(.+) (.+) (.+)') do
		local doConnect, _ = string.find(first_line, "CONNECT")
		local host = url
		if not doConnect then
			local start = string.find(url, "//", 1)
			start = start + 2
			local last =  string.find(url, "/", start)
			host = string.sub(url,start, last-1)
		end
		local idx = string.find(host, ':')
		if idx then
			local port = string.sub(host, idx + 1)
			port = tonumber(port)
			host = string.sub(host, 1, idx - 1)
			return method, host, port
		end
		return method, host,80 -- 默认是80端口
	end
	return nil
end

local function tunnel(from, to, name, msg)
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

local function is_ip_address(str)
	for p1, p2, p3, p4 in string.gmatch(str, '([0-9]+).([0-9]+).([0-9]+).([0-9]+)') do
		return true
	end
	return false
end

local function connect_to_remote(buf)
	local first, last = string.find(buf, '\r\n')
	local first_line = string.sub(buf, 1, first - 1)
	-- skynet.error('[首行]：',first_line)
	local method, host, port = parse(first_line)
	local ip
	if not is_ip_address(host) then
		ip = dns.resolve(host)
		ip = ip .. ":" .. tostring(port)
	else
		ip = host .. ":" .. tostring(port)
	end
	local id = socket.open(ip)
	assert(id, '建立链接失败')
	return id,method
end

local function handler(cID, addr)
	socket.start(cID)
	local buf = ''
	while true do
		local str = socket.read(cID)
		if str then
			buf = buf .. str
			if is_complete_header(buf) then
				local from = cID
				local to, method = connect_to_remote(buf)
				if method == 'CONNECT' then
					socket.write(cID, 'HTTP/1.1 200 Connection Established\r\n\r\n')
					-- 写入数据
					skynet.fork(tunnel, from, to, 'client')
					skynet.fork(tunnel, to, from, 'server')
					return
				end

				-- TODO 这里用自己的http服务测试post请求
			    --[first, last]  curl -x 127.0.0.1:8001 http://www.baidu.com:80 访问有问题，目前原因未知 302 重定向了
				if method == 'GET' or method == 'POST' then
					skynet.fork(tunnel, from, to,"client", buf)
					skynet.fork(tunnel, to, from, "server")
					return
				end

				error('[ERROR]:不支持的方法:'..method)
				return
			end
		else
			socket.close(cID)
			skynet.error(addr .. " disconnect")
			return
		end
	end
end

local function echo(cID, addr)
	local ok, msg = pcall(handler, cID, addr)
	if not ok then
		socket.close(cID)
		skynet.error('[ERROR]:',msg)
	end
end

local function accept(cID, addr)
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
