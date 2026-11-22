sub init()
    m.top.functionName = "loadOnDemand"
end sub

sub loadOnDemand()
    account = m.top.accountConfig
    if GetInterface(account, "ifAssociativeArray") = invalid
        failOnDemand("Provider account is unavailable")
        return
    end if
    server = onDemandText(account.server)
    while server.Right(1) = "/"
        server = server.Left(server.Len() - 1)
    end while
    username = account.username
    password = account.password
    if (server.Left(7) <> "http://" and server.Left(8) <> "https://") or GetInterface(username, "ifString") = invalid or GetInterface(password, "ifString") = invalid
        failOnDemand("Provider account is unavailable")
        return
    end if
    if username = "" or password = ""
        failOnDemand("Provider account is unavailable")
        return
    end if
    transfer = CreateObject("roUrlTransfer")
    userPart = transfer.Escape(username)
    passPart = transfer.Escape(password)
    api = server + "/player_api.php?username=" + userPart + "&password=" + passPart
    query = LCase(m.top.searchQuery.Trim())
    categoryId = m.top.categoryId
    categoriesOnly = categoryId = "" and query = ""
    idPattern = CreateObject("roRegex", "^[0-9]{1,32}$", "")
    if categoryId <> "" and not idPattern.IsMatch(categoryId)
        failOnDemand("Invalid movie category")
        return
    end if

    action = "get_vod_streams"
    if categoriesOnly then action = "get_vod_categories"
    url = api + "&action=" + action
    if categoryId <> "" then url = url + "&category_id=" + categoryId
    response = fetchOnDemandJson(transfer, url)
    if response.error <> invalid
        failOnDemand(response.error)
        return
    end if

    result = {providerMode: true, categories: [], channels: [], totalMatches: 0}
    if categoriesOnly
        for each row in response.rows
            if GetInterface(row, "ifAssociativeArray") <> invalid
                id = onDemandText(row.category_id)
                title = onDemandText(row.category_name).Left(200)
                if idPattern.IsMatch(id) and title <> ""
                    result.categories.Push({title: title, providerId: id, count: 0})
                end if
            end if
        end for
    else
        bytes = CreateObject("roByteArray")
        bytes.FromAsciiString(server + Chr(10) + userPart)
        digest = CreateObject("roEVPDigest")
        digest.Setup("sha256")
        accountScope = digest.Process(bytes)
        category = m.top.categoryName
        if category = "" then category = "Movies"
        limit = 2500
        if query <> "" then limit = 300
        streamBase = server + "/movie/" + userPart + "/" + passPart + "/"
        for each row in response.rows
            if GetInterface(row, "ifAssociativeArray") <> invalid
                name = onDemandText(row.name)
                if query = "" or LCase(name).Instr(query) >= 0 or onDemandText(row.stream_id) = query
                    movie = onDemandMovie(row, streamBase, category, accountScope)
                    if movie <> invalid
                        result.totalMatches = result.totalMatches + 1
                        if result.channels.Count() < limit then result.channels.Push(movie)
                    end if
                end if
            end if
        end for
    end if
    m.top.result = result
    m.top.status = "ok"
end sub

function fetchOnDemandJson(transfer as object, url as string) as object
    ' VOD catalogs can be much larger than live categories. Bound the file
    ' before reading or parsing it, and keep the transfer off the render thread.
    maxBytes = 8388608
    path = "tmp:/vod-" + CreateObject("roDeviceInfo").GetRandomUUID() + ".json"
    port = CreateObject("roMessagePort")
    transfer.SetMessagePort(port)
    transfer.SetUrl(url)
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.InitClientCertificates()
    transfer.EnableEncodings(true)
    transfer.AddHeader("User-Agent", "Mozilla/5.0")
    if not transfer.AsyncGetToFile(path)
        DeleteFile(path)
        return {error: "Could not start the movie request"}
    end if

    fs = CreateObject("roFileSystem")
    timer = CreateObject("roTimespan")
    code = 0
    tooLarge = false
    while timer.TotalMilliseconds() < 45000
        event = wait(150, port)
        if Type(event) = "roUrlEvent"
            code = event.GetResponseCode()
            exit while
        end if
        if onDemandFileSize(fs.Stat(path)) > maxBytes
            tooLarge = true
            exit while
        end if
    end while
    if code = 0 then transfer.AsyncCancel()
    size = onDemandFileSize(fs.Stat(path))
    result = {error: "Could not load movies from the provider"}
    if tooLarge or size > maxBytes
        result.error = "Movie catalog is too large. Try a category."
    else if code = 200 and size > 0
        rows = ParseJson(ReadAsciiFile(path))
        if GetInterface(rows, "ifArray") <> invalid
            result = {rows: rows}
        else
            result.error = "Provider did not return a movie list"
        end if
    else if code = 401 or code = 403
        result.error = "Provider denied access to movies"
    else if code = 0
        result.error = "Movie request timed out. Try again."
    end if
    DeleteFile(path)
    return result
end function

function onDemandFileSize(stat as dynamic) as integer
    if GetInterface(stat, "ifAssociativeArray") = invalid then return 0
    if GetInterface(stat.size, "ifInt") = invalid then return 0
    return stat.size.GetInt()
end function

sub failOnDemand(message as string)
    m.top.error = message
    m.top.status = "error"
end sub
