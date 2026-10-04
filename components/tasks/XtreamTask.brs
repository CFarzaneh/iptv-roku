' Live TV only: avoid the provider's slow combined M3U/VOD export.
sub init()
    m.top.functionName = "runLive"
end sub

sub runLive()
    account = m.top.accountConfig
    if account = invalid
        failLive("Account configuration is missing")
        return
    end if
    server = liveString(account.server).Trim()
    username = liveString(account.username)
    password = liveString(account.password)
    while server.EndsWith("/")
        server = server.Left(server.Len() - 1)
    end while
    if (not server.StartsWith("http://") and not server.StartsWith("https://")) or username = "" or password = ""
        failLive("Account configuration is incomplete")
        return
    end if

    encoder = CreateObject("roUrlTransfer")
    userPart = encoder.Escape(username)
    passPart = encoder.Escape(password)
    api = server + "/player_api.php?username=" + userPart + "&password=" + passPart
    streamBase = server + "/live/" + userPart + "/" + passPart + "/"

    searchQuery = liveString(m.top.searchQuery).Trim()
    categoryId = liveString(m.top.categoryId)
    if searchQuery <> ""
        loadChannelSearch(api, streamBase, searchQuery)
    else if categoryId = ""
        loadCategoryList(api)
    else
        loadChannelCategory(api, streamBase, categoryId, liveString(m.top.categoryName))
    end if
end sub

sub loadChannelSearch(api as string, streamBase as string, query as string)
    response = liveJson(api + "&action=get_live_streams")
    if not response.ok
        failLive(response.error)
        return
    end if
    if GetInterface(response.data, "ifArray") = invalid
        failLive("Provider did not return a live channel list")
        return
    end if

    idPattern = CreateObject("roRegex", "^[0-9]+$", "")
    qLower = LCase(query)
    channels = []
    exactChannel = invalid
    totalMatches = 0
    for each row in response.data
        if GetInterface(row, "ifAssociativeArray") <> invalid
            streamId = liveString(row.stream_id)
            name = liveString(row.name)
            epgName = liveString(row.epg_channel_id)
            if name <> "" and idPattern.IsMatch(streamId)
                idMatch = (streamId = query)
                if idMatch or Instr(1, LCase(name), qLower) > 0 or (epgName <> "" and Instr(1, LCase(epgName), qLower) > 0)
                    totalMatches = totalMatches + 1
                    channel = {
                        name: name,
                        url: streamBase + streamId + ".m3u8",
                        providerStreamId: streamId,
                        group: "Search results",
                        logo: liveString(row.stream_icon),
                        tvgId: epgName,
                        tvgName: name,
                        streamType: "hls",
                        compatible: true,
                        catchup: false
                    }
                    if idMatch
                        exactChannel = channel
                    else if channels.Count() < 500
                        channels.Push(channel)
                    end if
                end if
            end if
        end if
    end for
    if exactChannel <> invalid
        ordered = [exactChannel]
        for each channel in channels
            if ordered.Count() >= 500 then exit for
            ordered.Push(channel)
        end for
        channels = ordered
    end if

    result = {
        version: 1,
        fetchedAt: CreateObject("roDateTime").AsSeconds(),
        source: "network",
        epgUrl: "",
        channels: channels,
        categories: [],
        providerMode: true,
        totalMatches: totalMatches
    }
    m.top.result = result
    m.top.status = "ok"
end sub

sub loadCategoryList(api as string)
    response = liveJson(api + "&action=get_live_categories")
    if not response.ok
        failLive(response.error)
        return
    end if
    if GetInterface(response.data, "ifArray") = invalid
        failLive("Provider did not return a category list; check the account")
        return
    end if

    idPattern = CreateObject("roRegex", "^[0-9]+$", "")
    categories = []
    for each row in response.data
        if GetInterface(row, "ifAssociativeArray") <> invalid
            categoryId = liveString(row.category_id)
            categoryName = liveString(row.category_name)
            if categoryName <> "" and idPattern.IsMatch(categoryId)
                categories.Push({ title: categoryName, count: 0, providerId: categoryId })
            end if
        end if
    end for
    if categories.Count() = 0
        failLive("Provider returned no usable live categories")
        return
    end if
    result = {
        version: 1,
        fetchedAt: CreateObject("roDateTime").AsSeconds(),
        source: "network",
        epgUrl: "",
        channels: [],
        categories: categories,
        providerMode: true
    }
    m.top.result = result
    m.top.status = "ok"
end sub

sub loadChannelCategory(api as string, streamBase as string, categoryId as string, categoryName as string)
    idPattern = CreateObject("roRegex", "^[0-9]+$", "")
    if not idPattern.IsMatch(categoryId)
        failLive("Invalid provider category")
        return
    end if
    response = liveJson(api + "&action=get_live_streams&category_id=" + categoryId)
    if not response.ok
        failLive(response.error)
        return
    end if
    if GetInterface(response.data, "ifArray") = invalid
        failLive("Provider did not return a live channel list")
        return
    end if

    channels = []
    for each row in response.data
        if GetInterface(row, "ifAssociativeArray") <> invalid
            streamId = liveString(row.stream_id)
            name = liveString(row.name)
            if name <> "" and idPattern.IsMatch(streamId)
                channels.Push({
                    name: name,
                    url: streamBase + streamId + ".m3u8",
                    providerStreamId: streamId,
                    group: categoryName,
                    logo: liveString(row.stream_icon),
                    tvgId: liveString(row.epg_channel_id),
                    tvgName: name,
                    streamType: "hls",
                    compatible: true,
                    catchup: false
                })
            end if
        end if
    end for
    if channels.Count() = 0
        failLive("This category has no usable live channels")
        return
    end if
    if channels.Count() > 2500
        failLive("This category is too large for this Roku player")
        return
    end if

    result = {
        version: 1,
        fetchedAt: CreateObject("roDateTime").AsSeconds(),
        source: "network",
        epgUrl: "",
        channels: channels,
        categories: [{ title: categoryName, count: channels.Count(), providerId: categoryId }],
        providerMode: true
    }
    m.top.result = result
    m.top.status = "ok"
end sub

function liveString(value as dynamic) as string
    if GetInterface(value, "ifString") <> invalid then return value
    if GetInterface(value, "ifInt") <> invalid then return value.ToStr()
    return ""
end function

function liveJson(url as string) as object
    req = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    req.SetMessagePort(port)
    req.SetUrl(url)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.InitClientCertificates()
    req.EnableEncodings(true)
    req.AddHeader("User-Agent", "Mozilla/5.0")
    if not req.AsyncGetToString()
        return { ok: false, error: "Could not start the provider request" }
    end if
    event = wait(60000, port)
    if type(event) <> "roUrlEvent"
        req.AsyncCancel()
        return { ok: false, error: "Provider did not respond within 60 seconds" }
    end if
    code = event.GetResponseCode()
    if code <> 200
        ' Do not expose URLs, credentials or server-supplied error bodies.
        if code = 401 or code = 403 then return { ok: false, error: "Provider rejected access; check the account or network restrictions" }
        if code = -6 then return { ok: false, error: "Could not resolve the provider address" }
        if code = -7 then return { ok: false, error: "Could not connect to the provider" }
        if code = -28 then return { ok: false, error: "Provider connection timed out" }
        return { ok: false, error: "Provider request failed (code " + code.ToStr() + ")" }
    end if
    body = event.GetString()
    ' This limits parsing, not the initial in-memory network response.
    if body.Len() > 20000000 then return { ok: false, error: "Provider response is too large for this player" }
    data = ParseJson(body)
    if data = invalid then return { ok: false, error: "Provider returned invalid channel data" }
    return { ok: true, data: data }
end function

sub failLive(reason as string)
    m.top.error = reason
    m.top.status = "error"
end sub
