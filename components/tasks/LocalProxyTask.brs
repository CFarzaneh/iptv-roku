sub init()
    m.top.functionName = "runServer"
end sub

sub runServer()
    m.listenPort = m.top.listenPort
    if m.listenPort <= 0 then m.listenPort = 8765
    m.segmentUrls = {}
    m.eventSequence = 0

    eventPort = CreateObject("roMessagePort")
    listener = CreateObject("roStreamSocket")
    listener.SetMessagePort(eventPort)
    address = CreateObject("roSocketAddress")
    ' Bind only to loopback. Provider URLs and credentials must never be exposed to
    ' another device on the LAN.
    address.SetAddress("127.0.0.1:" + m.listenPort.ToStr())
    listener.SetAddress(address)
    listener.NotifyReadable(true)
    listener.Listen(4)
    if not listener.eOK()
        m.top.error = "listen failed"
        m.top.status = "error"
        return
    end if

    connections = {}
    m.top.status = "ready"
    while true
        event = Wait(0, eventPort)
        if Type(event) = "roSocketEvent"
            socketId = event.GetSocketID()
            if socketId = listener.GetID() and listener.IsReadable()
                connection = listener.Accept()
                if connection <> invalid
                    connection.SetMessagePort(eventPort)
                    connection.NotifyReadable(true)
                    connections[socketIdKey(connection.GetID())] = {
                        socket: connection,
                        phase: "reading"
                    }
                end if
            else
                key = socketIdKey(socketId)
                if connections.DoesExist(key)
                    state = connections[key]
                    if state.phase = "reading" and state.socket.IsReadable()
                        receiveRequest(key, connections)
                    else if state.phase = "sending" and state.socket.IsWritable()
                        sendPending(key, connections)
                    end if
                end if
            end if
        end if
    end while
end sub

sub receiveRequest(key as string, connections as object)
    state = connections[key]
    requestBuffer = CreateObject("roByteArray")
    requestBuffer[8191] = 0
    received = state.socket.Receive(requestBuffer, 0, 8192)
    if received <= 0
        closeConnection(key, connections)
        return
    end if

    requestText = requestBuffer.ToAsciiString().Left(received)
    firstLine = requestText
    lineEnd = firstLine.Instr(Chr(13) + Chr(10))
    if lineEnd >= 0 then firstLine = firstLine.Left(lineEnd)
    m.top.lastRequest = firstLine
    m.top.requestCount = m.top.requestCount + 1

    response = buildResponse(firstLine)
    headerText = responseHeader(response.code, response.contentType, response.body.Count())
    headerBytes = CreateObject("roByteArray")
    headerBytes.FromAsciiString(headerText)
    state.phase = "sending"
    state.header = headerBytes
    state.headerOffset = 0
    state.body = response.body
    state.bodyOffset = 0
    state.socket.NotifyReadable(false)
    state.socket.NotifyWritable(true)
    connections[key] = state
    sendPending(key, connections)
end sub

function buildResponse(requestLine as string) as object
    path = requestPath(requestLine)
    if path = "/probe.m3u8"
        body = CreateObject("roByteArray")
        body.FromAsciiString(staticProbeManifest())
        noteEvent("static manifest bytes=" + body.Count().ToStr())
        return { code: 200, contentType: "application/vnd.apple.mpegurl", body: body }
    else if path = "/proxy.m3u8"
        return fetchRelayManifest()
    else if path.StartsWith("/segment/")
        return fetchRelaySegment(path.Mid(9))
    end if

    body = CreateObject("roByteArray")
    body.FromAsciiString("not found")
    noteEvent("404 path")
    return { code: 404, contentType: "text/plain", body: body }
end function

function fetchRelayManifest() as object
    resolvedUrl = resolveFinalUrl(m.top.sourceUrl)
    transfer = newTransfer(resolvedUrl)
    manifest = transfer.GetToString()
    if manifest = invalid or manifest = ""
        noteEvent("manifest upstream empty")
        body = CreateObject("roByteArray")
        body.FromAsciiString("upstream manifest unavailable")
        return { code: 502, contentType: "text/plain", body: body }
    end if

    rewritten = rewriteManifest(manifest, resolvedUrl)
    body = CreateObject("roByteArray")
    body.FromAsciiString(rewritten)
    noteEvent("manifest relayed bytes=" + body.Count().ToStr() + " segments=" + m.segmentUrls.Count().ToStr())
    return { code: 200, contentType: "application/vnd.apple.mpegurl", body: body }
end function

function resolveFinalUrl(url as string) as string
    current = url
    for redirectCount = 0 to 4
        location = rawHeadLocation(current)
        if location = "" then return current
        current = resolveUrl(current, location)
        noteEvent("manifest redirect followed")
    end for
    return current
end function

function rawHeadLocation(url as string) as string
    lower = LCase(url)
    if not lower.StartsWith("http://") then return ""
    remainder = url.Mid(7)
    slashAt = remainder.Instr("/")
    authority = remainder
    path = "/"
    if slashAt >= 0
        authority = remainder.Left(slashAt)
        path = remainder.Mid(slashAt)
    end if
    if authority = "" then return ""

    connectAddress = authority
    if authority.Instr(":") < 0 then connectAddress = authority + ":80"
    address = CreateObject("roSocketAddress")
    if not address.SetAddress(connectAddress) or not address.IsAddressValid() then return ""
    socket = CreateObject("roStreamSocket")
    socket.SetSendToAddress(address)
    if not socket.Connect() then return ""

    crlf = Chr(13) + Chr(10)
    request = "HEAD " + path + " HTTP/1.1" + crlf
    request = request + "Host: " + authority + crlf
    request = request + "User-Agent: Mozilla/5.0" + crlf
    request = request + "Accept: */*" + crlf
    request = request + "Connection: close" + crlf + crlf
    if socket.SendStr(request) <= 0
        socket.Close()
        return ""
    end if

    response = ""
    while response.Len() < 65536
        chunk = socket.ReceiveStr(4096)
        if chunk = "" then exit while
        response = response + chunk
    end while
    socket.Close()
    headerEnd = response.Instr(crlf + crlf)
    if headerEnd >= 0 then response = response.Left(headerEnd)
    lines = response.Split(crlf)
    for each line in lines
        colonAt = line.Instr(":")
        if colonAt > 0 and LCase(line.Left(colonAt).Trim()) = "location"
            return line.Mid(colonAt + 1).Trim()
        end if
    end for
    return ""
end function

function resolveUrl(baseUrl as string, relativeUrl as string) as string
    lower = LCase(relativeUrl)
    if lower.StartsWith("http://") or lower.StartsWith("https://") then return relativeUrl
    if relativeUrl.StartsWith("//")
        schemeEnd = baseUrl.Instr(":")
        if schemeEnd >= 0 then return baseUrl.Left(schemeEnd + 1) + relativeUrl
    end if
    if relativeUrl.StartsWith("/") then return urlOrigin(baseUrl) + relativeUrl
    return urlDirectory(baseUrl) + relativeUrl
end function

function urlOrigin(url as string) as string
    schemeAt = url.Instr("://")
    if schemeAt < 0 then return ""
    pathAt = -1
    for i = schemeAt + 3 to url.Len() - 1
        if url.Mid(i, 1) = "/"
            pathAt = i
            exit for
        end if
    end for
    if pathAt < 0 then return url
    return url.Left(pathAt)
end function

function fetchRelaySegment(segmentId as string) as object
    body = CreateObject("roByteArray")
    if segmentId = "" or not m.segmentUrls.DoesExist(segmentId)
        body.FromAsciiString("unknown segment")
        noteEvent("segment map miss")
        return { code: 404, contentType: "text/plain", body: body }
    end if

    tempPath = "tmp:/relay-" + m.top.requestCount.ToStr().Trim() + ".ts"
    transfer = newTransfer(m.segmentUrls[segmentId])
    code = transfer.GetToFile(tempPath)
    if code <> 200 or not body.ReadFile(tempPath)
        DeleteFile(tempPath)
        body.Clear()
        body.FromAsciiString("upstream segment unavailable")
        noteEvent("segment upstream code=" + code.ToStr())
        return { code: 502, contentType: "text/plain", body: body }
    end if
    DeleteFile(tempPath)
    if m.top.transformMode = "aac-main-to-lc"
        transform = relabelAacMainToLc(body)
        noteEvent("AAC headers pid=" + transform.pid.ToStr().Trim() + " frames=" + transform.frames.ToStr().Trim() + " changed=" + transform.changed.ToStr().Trim())
    end if
    noteEvent("segment relayed bytes=" + body.Count().ToStr())
    return { code: 200, contentType: "video/mp2t", body: body }
end function

function relabelAacMainToLc(data as object) as object
    audioPid = findAdtsAudioPid(data)
    result = { pid: audioPid, frames: 0, changed: 0 }
    if audioPid < 0 then return result

    frameRemaining = 0
    headerBytes = []
    headerPositions = []
    for packetStart = 0 to data.Count() - 188 step 188
        if data[packetStart] <> &h47 then goto nextPacket
        pid = (data[packetStart + 1] and &h1f) * 256 + data[packetStart + 2]
        if pid <> audioPid then goto nextPacket
        control = Int((data[packetStart + 3] and &h30) / 16)
        if control <> 1 and control <> 3 then goto nextPacket
        payloadStart = packetStart + 4
        if control = 3 then payloadStart = payloadStart + 1 + data[payloadStart]
        packetEnd = packetStart + 188
        if payloadStart >= packetEnd then goto nextPacket

        payloadStartsUnit = (data[packetStart + 1] and &h40) <> 0
        if payloadStartsUnit and payloadStart + 9 <= packetEnd
            if data[payloadStart] = 0 and data[payloadStart + 1] = 0 and data[payloadStart + 2] = 1
                payloadStart = payloadStart + 9 + data[payloadStart + 8]
            end if
        end if

        position = payloadStart
        while position < packetEnd
            if frameRemaining > 0
                available = packetEnd - position
                used = frameRemaining
                if used > available then used = available
                frameRemaining = frameRemaining - used
                position = position + used
            else if headerBytes.Count() = 0
                if data[position] = &hff
                    headerBytes.Push(data[position])
                    headerPositions.Push(position)
                end if
                position = position + 1
            else
                headerBytes.Push(data[position])
                headerPositions.Push(position)
                position = position + 1

                if headerBytes.Count() = 2 and (headerBytes[1] and &hf6) <> &hf0
                    lastByte = headerBytes[1]
                    lastPosition = headerPositions[1]
                    headerBytes = []
                    headerPositions = []
                    if lastByte = &hff
                        headerBytes.Push(lastByte)
                        headerPositions.Push(lastPosition)
                    end if
                else if headerBytes.Count() = 7
                    frequencyIndex = Int((headerBytes[2] and &h3c) / 4)
                    frameLength = (headerBytes[3] and 3) * 2048 + headerBytes[4] * 8 + Int((headerBytes[5] and &he0) / 32)
                    if frequencyIndex < 15 and frameLength >= 7
                        result.frames = result.frames + 1
                        profile = Int((headerBytes[2] and &hc0) / 64)
                        if profile = 0
                            data[headerPositions[2]] = (data[headerPositions[2]] and &h3f) or &h40
                            result.changed = result.changed + 1
                        end if
                        frameRemaining = frameLength - 7
                        headerBytes = []
                        headerPositions = []
                    else
                        lastByte = headerBytes[6]
                        lastPosition = headerPositions[6]
                        headerBytes = []
                        headerPositions = []
                        if lastByte = &hff
                            headerBytes.Push(lastByte)
                            headerPositions.Push(lastPosition)
                        end if
                    end if
                end if
            end if
        end while
nextPacket:
    end for
    return result
end function

function findAdtsAudioPid(data as object) as integer
    pmtPid = findPmtPid(data)
    if pmtPid < 0 then return -1
    for packetStart = 0 to data.Count() - 188 step 188
        if data[packetStart] <> &h47 then goto nextPmtPacket
        pid = (data[packetStart + 1] and &h1f) * 256 + data[packetStart + 2]
        if pid <> pmtPid or (data[packetStart + 1] and &h40) = 0 then goto nextPmtPacket
        payloadStart = tsPayloadStart(data, packetStart)
        packetEnd = packetStart + 188
        if payloadStart < 0 or payloadStart >= packetEnd then goto nextPmtPacket
        sectionStart = payloadStart + 1 + data[payloadStart]
        if sectionStart + 12 > packetEnd or data[sectionStart] <> 2 then goto nextPmtPacket
        sectionLength = (data[sectionStart + 1] and 15) * 256 + data[sectionStart + 2]
        sectionEnd = sectionStart + 3 + sectionLength - 4
        if sectionEnd > packetEnd then sectionEnd = packetEnd
        programInfoLength = (data[sectionStart + 10] and 15) * 256 + data[sectionStart + 11]
        position = sectionStart + 12 + programInfoLength
        while position + 5 <= sectionEnd
            streamType = data[position]
            elementaryPid = (data[position + 1] and &h1f) * 256 + data[position + 2]
            infoLength = (data[position + 3] and 15) * 256 + data[position + 4]
            if streamType = &h0f or streamType = &h11 then return elementaryPid
            position = position + 5 + infoLength
        end while
nextPmtPacket:
    end for
    return -1
end function

function findPmtPid(data as object) as integer
    for packetStart = 0 to data.Count() - 188 step 188
        if data[packetStart] <> &h47 then goto nextPatPacket
        pid = (data[packetStart + 1] and &h1f) * 256 + data[packetStart + 2]
        if pid <> 0 or (data[packetStart + 1] and &h40) = 0 then goto nextPatPacket
        payloadStart = tsPayloadStart(data, packetStart)
        packetEnd = packetStart + 188
        if payloadStart < 0 or payloadStart >= packetEnd then goto nextPatPacket
        sectionStart = payloadStart + 1 + data[payloadStart]
        if sectionStart + 8 > packetEnd or data[sectionStart] <> 0 then goto nextPatPacket
        sectionLength = (data[sectionStart + 1] and 15) * 256 + data[sectionStart + 2]
        sectionEnd = sectionStart + 3 + sectionLength - 4
        if sectionEnd > packetEnd then sectionEnd = packetEnd
        position = sectionStart + 8
        while position + 4 <= sectionEnd
            programNumber = data[position] * 256 + data[position + 1]
            if programNumber <> 0
                return (data[position + 2] and &h1f) * 256 + data[position + 3]
            end if
            position = position + 4
        end while
nextPatPacket:
    end for
    return -1
end function

function tsPayloadStart(data as object, packetStart as integer) as integer
    control = Int((data[packetStart + 3] and &h30) / 16)
    if control <> 1 and control <> 3 then return -1
    payloadStart = packetStart + 4
    if control = 3 then payloadStart = payloadStart + 1 + data[payloadStart]
    if payloadStart > packetStart + 188 then return -1
    return payloadStart
end function

function newTransfer(url as string) as object
    transfer = CreateObject("roUrlTransfer")
    transfer.SetUrl(url)
    transfer.AddHeader("User-Agent", "Mozilla/5.0")
    transfer.EnableEncodings(true)
    if LCase(url).StartsWith("https://")
        transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        transfer.InitClientCertificates()
    end if
    transfer.RetainBodyOnError(true)
    return transfer
end function

function rewriteManifest(manifest as string, sourceUrl as string) as string
    m.segmentUrls = {}
    sourceBase = urlDirectory(sourceUrl)
    crlf = Chr(13) + Chr(10)
    output = ""
    lines = manifest.Split(Chr(10))
    for each rawLine in lines
        line = rawLine.Trim()
        if line = "" or line.StartsWith("#")
            output = output + line + crlf
        else
            upstream = resolveUrl(sourceBase, line)
            segmentId = safeSegmentId(upstream)
            m.segmentUrls[segmentId] = upstream
            output = output + "/segment/" + segmentId + crlf
        end if
    end for
    return output
end function

function urlDirectory(url as string) as string
    lastSlash = -1
    for i = 0 to url.Len() - 1
        if url.Mid(i, 1) = "/" then lastSlash = i
    end for
    if lastSlash < 0 then return url
    return url.Left(lastSlash + 1)
end function

function safeSegmentId(url as string) as string
    clean = url
    queryPos = clean.Instr("?")
    if queryPos >= 0 then clean = clean.Left(queryPos)
    slashPos = -1
    for i = 0 to clean.Len() - 1
        if clean.Mid(i, 1) = "/" then slashPos = i
    end for
    if slashPos >= 0 then clean = clean.Mid(slashPos + 1)

    result = ""
    for i = 0 to clean.Len() - 1
        ch = clean.Mid(i, 1)
        code = Asc(ch)
        allowed = (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or ch = "." or ch = "-" or ch = "_"
        if allowed then result = result + ch
    end for
    if result = "" then result = "segment-" + m.segmentUrls.Count().ToStr().Trim() + ".ts"
    return result
end function

sub sendPending(key as string, connections as object)
    if not connections.DoesExist(key) then return
    state = connections[key]
    for pass = 0 to 7
        if not state.socket.IsWritable() then exit for
        if state.headerOffset < state.header.Count()
            remaining = state.header.Count() - state.headerOffset
            if remaining > 32768 then remaining = 32768
            sent = state.socket.Send(state.header, state.headerOffset, remaining)
            if sent <= 0 then exit for
            state.headerOffset = state.headerOffset + sent
        else if state.bodyOffset < state.body.Count()
            remaining = state.body.Count() - state.bodyOffset
            if remaining > 32768 then remaining = 32768
            sent = state.socket.Send(state.body, state.bodyOffset, remaining)
            if sent <= 0 then exit for
            state.bodyOffset = state.bodyOffset + sent
        else
            noteEvent("response complete bytes=" + state.body.Count().ToStr().Trim())
            closeConnection(key, connections)
            return
        end if
    end for
    connections[key] = state
end sub

sub closeConnection(key as string, connections as object)
    if not connections.DoesExist(key) then return
    state = connections[key]
    state.socket.NotifyReadable(false)
    state.socket.NotifyWritable(false)
    state.socket.Close()
    connections.Delete(key)
end sub

function responseHeader(code as integer, contentType as string, length as integer) as string
    reason = "OK"
    if code = 404 then reason = "Not Found"
    if code = 502 then reason = "Bad Gateway"
    crlf = Chr(13) + Chr(10)
    return "HTTP/1.1 " + code.ToStr().Trim() + " " + reason + crlf + "Content-Type: " + contentType + crlf + "Content-Length: " + length.ToStr().Trim() + crlf + "Cache-Control: no-store" + crlf + "Connection: close" + crlf + crlf
end function

function requestPath(requestLine as string) as string
    parts = requestLine.Split(" ")
    if parts.Count() < 2 then return ""
    path = parts[1]
    queryPos = path.Instr("?")
    if queryPos >= 0 then path = path.Left(queryPos)
    return path
end function

function socketIdKey(socketId as dynamic) as string
    return socketId.ToStr().Trim()
end function

sub noteEvent(text as string)
    m.eventSequence = m.eventSequence + 1
    m.top.lastEvent = m.eventSequence.ToStr().Trim() + " " + text
end sub

function staticProbeManifest() as string
    crlf = Chr(13) + Chr(10)
    body = "#EXTM3U" + crlf
    body = body + "#EXT-X-VERSION:3" + crlf
    body = body + "#EXT-X-TARGETDURATION:1" + crlf
    body = body + "#EXT-X-MEDIA-SEQUENCE:0" + crlf
    body = body + "#EXTINF:1.0," + crlf
    body = body + "probe.ts" + crlf
    return body + "#EXT-X-ENDLIST" + crlf
end function
