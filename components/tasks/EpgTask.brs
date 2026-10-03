' EpgTask: downloads epg.json, caches it, parses it

sub init()
    m.top.functionName = "runEpg"
end sub

sub runEpg()
    if m.top.providerConfig <> invalid
        runProviderEpg()
        return
    end if

    url = m.top.epgUrl
    if url = invalid or url = ""
        failEpg("no EPG URL configured")
        return
    end if

    port = CreateObject("roMessagePort")
    req = CreateObject("roUrlTransfer")
    req.SetUrl(url)
    req.SetMessagePort(port)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.InitClientCertificates()
    req.EnableEncodings(true)

    reason = "request could not be started"
    if req.AsyncGetToString()
        msg = wait(30000, port)
        if type(msg) = "roUrlEvent"
            code = msg.GetResponseCode()
            if code = 200
                body = msg.GetString()
                if body <> ""
                    parsed = ParseJson(body)
                    if isUsableEpgPayload(parsed)
                        WriteAsciiFile("cachefs:/epg.json", body)

                        m.top.result = parsed
                        m.top.status = "ok"
                        return
                    else
                        reason = "response was not a usable guide"
                    end if
                else
                    reason = "empty response body"
                end if
            else
                reason = "HTTP " + code.ToStr()
            end if
        else
            reason = "timed out after 30s"
        end if
    end if

    ' Network path failed. Fall back to the cache -- a stale guide beats none.
    fs = CreateObject("roFileSystem")
    if fs.Exists("cachefs:/epg.json")
        body = ReadAsciiFile("cachefs:/epg.json")
        parsed = ParseJson(body)
        if parsed <> invalid and parsed.providerAuto <> true and isUsableEpgPayload(parsed)
            m.top.result = parsed
            m.top.status = "cache"
            return
        end if
        failEpg(reason + "; cached guide unusable too")
        return
    end if

    failEpg(reason + "; no cached guide")
end sub

' The provider's XMLTV document is larger than a Roku should hold in memory. Fetch
' short listings only for channels in categories the user has loaded, then merge
' them into a small device-side guide cache keyed by the app's channel names.
sub runProviderEpg()
    account = m.top.providerConfig
    server = providerString(account.server).Trim()
    username = providerString(account.username)
    password = providerString(account.password)
    while server.EndsWith("/")
        server = server.Left(server.Len() - 1)
    end while
    if (not server.StartsWith("http://") and not server.StartsWith("https://")) or username = "" or password = ""
        failEpg("automatic provider EPG configuration is incomplete")
        return
    end if

    encoder = CreateObject("roUrlTransfer")
    api = server + "/player_api.php?username=" + encoder.Escape(username) + "&password=" + encoder.Escape(password)
    epgMap = {}
    fs = CreateObject("roFileSystem")
    if fs.Exists("cachefs:/epg.json")
        cached = ParseJson(ReadAsciiFile("cachefs:/epg.json"))
        if cached <> invalid and cached.providerAuto = true and cached.epg <> invalid
            if GetInterface(cached.epg, "ifAssociativeArray") <> invalid then epgMap = cached.epg
        end if
    end if

    channels = m.top.providerChannels
    if channels = invalid then channels = []
    startedAt = CreateObject("roDateTime").AsSeconds()
    requestCount = 0
    for each ch in channels
        if CreateObject("roDateTime").AsSeconds() - startedAt >= 50 then exit for
        streamId = providerString(ch.providerStreamId)
        epgId = providerString(ch.tvgId)
        if streamId <> "" and epgId <> "" and requestCount < 120
            response = providerJson(api + "&action=get_short_epg&limit=4&stream_id=" + encoder.Escape(streamId))
            requestCount = requestCount + 1
            if response.ok and GetInterface(response.data, "ifAssociativeArray") <> invalid
                listings = response.data.epg_listings
                if GetInterface(listings, "ifArray") <> invalid
                    programmes = []
                    for each row in listings
                        if GetInterface(row, "ifAssociativeArray") <> invalid
                            startTime = providerEpoch(row.start_timestamp)
                            stopTime = providerEpoch(row.stop_timestamp)
                            title = decodeProviderText(providerString(row.title))
                            if startTime > 0 and stopTime > startTime and title <> ""
                                programmes.Push({ s: startTime, e: stopTime, t: title })
                            end if
                        end if
                    end for
                    if programmes.Count() > 0 then epgMap[ch.name] = programmes
                end if
            end if
        end if
    end for

    now = CreateObject("roDateTime").AsSeconds()
    payload = {
        count: epgMap.Count(),
        generated: now,
        epg: epgMap,
        providerAuto: true
    }
    if epgMap.Count() > 0 then WriteAsciiFile("cachefs:/epg.json", FormatJson(payload))
    m.top.result = payload
    m.top.status = "ok"
end sub

function providerJson(url as string) as object
    req = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    req.SetMessagePort(port)
    req.SetUrl(url)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.InitClientCertificates()
    req.EnableEncodings(true)
    req.AddHeader("User-Agent", "Mozilla/5.0")
    if not req.AsyncGetToString() then return { ok: false }
    event = wait(5000, port)
    if type(event) <> "roUrlEvent"
        req.AsyncCancel()
        return { ok: false }
    end if
    if event.GetResponseCode() <> 200 then return { ok: false }
    body = event.GetString()
    if body = "" or body.Len() > 1000000 then return { ok: false }
    data = ParseJson(body)
    if data = invalid then return { ok: false }
    return { ok: true, data: data }
end function

function providerString(value as dynamic) as string
    if GetInterface(value, "ifString") <> invalid then return value
    if GetInterface(value, "ifInt") <> invalid then return value.ToStr()
    return ""
end function

function providerEpoch(value as dynamic) as integer
    raw = providerString(value)
    if raw = "" then return 0
    return Int(Val(raw))
end function

function decodeProviderText(value as string) as string
    if value = "" then return ""
    bytes = CreateObject("roByteArray")
    bytes.FromBase64String(value)
    return bytes.ToAsciiString()
end function

' Set the reason BEFORE the status: status is the observed field, so MainScene must
' find `error` already populated when its handler runs.
' The URL is deliberately not included -- the user can type any URL in Settings, and
' PlaylistTask.maskToken is not in this component's namespace.
sub failEpg(reason as string)
    m.top.error = reason
    m.top.status = "error"
end sub

function isUsableEpgPayload(parsed as dynamic) as boolean
    if parsed = invalid then return false
    if GetInterface(parsed, "ifAssociativeArray") = invalid then return false
    if parsed.epg = invalid then return false
    if GetInterface(parsed.epg, "ifAssociativeArray") = invalid then return false
    ' An empty map is structurally valid and useless. Rejecting it stops a degenerate
    ' publish ({"count":0,"epg":{}}) from overwriting a good cache with nothing. The
    ' map is checked rather than the payload's own `count`, which is self-reported.
    ' Zero is the only scale-free threshold: this file is keyed by the curated
    ' channels.txt names, so the device cannot know how many entries to expect. The
    ' real floor lives upstream in epg/generate_epg.py, which knows that number.
    return parsed.epg.Count() > 0
end function
