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
    idPattern = CreateObject("roRegex", "^[0-9]{1,32}$", "")
    if categoryId <> "" and not idPattern.IsMatch(categoryId)
        failOnDemand("Invalid movie category")
        return
    end if

    result = {providerMode: true, categories: [], channels: [], totalMatches: 0}
    if categoryId = "" and query = ""
        response = fetchOnDemandJson(api + "&action=get_vod_categories")
        if response.error <> invalid
            failOnDemand(response.error)
            return
        end if
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
        catalog = {
            streamsUrl: api + "&action=get_vod_streams",
            streamBase: server + "/movie/" + userPart + "/" + passPart + "/",
            accountScope: digest.Process(bytes),
            query: query
        }
        categories = m.top.searchCategories
        if query <> "" and categoryId = "" and categories <> invalid and categories.Count() > 0
            searchMovieCategories(result, catalog, categories, fetchOnDemandJson)
        else
            url = catalog.streamsUrl
            if categoryId <> "" then url = url + "&category_id=" + categoryId
            response = fetchOnDemandJson(url)
            if response.error <> invalid
                failOnDemand(response.error)
                return
            end if
            category = m.top.categoryName
            if category = "" then category = "Movies"
            limit = 2500
            if query <> "" then limit = 300
            collectMovies(result, catalog, response.rows, category, {}, limit)
        end if
    end if
    if m.top.cancelRequested then return
    if result.error <> invalid
        failOnDemand(result.error)
        return
    end if
    m.top.result = result
    m.top.status = "ok"
end sub

sub searchMovieCategories(result as object, catalog as object, categories as object, fetch as function)
    clock = CreateObject("roTimespan")
    seenCategories = {}
    seenMovies = {}
    idPattern = CreateObject("roRegex", "^[0-9]{1,32}$", "")
    total = categories.Count()
    skipped = 0
    checked = 0
    firstError = ""
    for i = 0 to total - 1
        if m.top.cancelRequested then return
        category = categories[i]
        id = onDemandText(category.providerId)
        if idPattern.IsMatch(id) and not seenCategories.DoesExist(id)
            remaining = 120000 - clock.TotalMilliseconds()
            if remaining <= 0
                skipped = skipped + total - i
                exit for
            end if
            seenCategories[id] = true
            m.top.searchProgress = {current: i + 1, total: total}
            timeout = 10000
            if remaining < timeout then timeout = remaining
            response = fetch(catalog.streamsUrl + "&category_id=" + id, timeout)
            if response.error <> invalid
                if firstError = "" then firstError = response.error
                skipped = skipped + 1
                if response.httpCode = 401 or response.httpCode = 403 or response.httpCode = 429
                    skipped = skipped + total - i - 1
                    exit for
                end if
            else
                checked = checked + 1
                collectMovies(result, catalog, response.rows, category.title, seenMovies, 300)
            end if
        end if
    end for
    result.incomplete = skipped > 0
    if checked = 0 and firstError <> "" then result.error = firstError
end sub

sub collectMovies(result as object, catalog as object, rows as object, category as string, seen as object, limit as integer)
    for each row in rows
        if m.top.cancelRequested then return
        if GetInterface(row, "ifAssociativeArray") <> invalid
            id = onDemandText(row.stream_id)
            name = onDemandText(row.name)
            query = catalog.query
            if not seen.DoesExist(id) and (query = "" or LCase(name).Instr(query) >= 0 or id = query)
                movie = onDemandMovie(row, catalog.streamBase, category, catalog.accountScope)
                if movie <> invalid
                    seen[id] = true
                    result.totalMatches = result.totalMatches + 1
                    if result.channels.Count() < limit then result.channels.Push(movie)
                end if
            end if
        end if
    end for
end sub

function fetchOnDemandJson(url as string, timeoutMs = 45000 as integer) as object
    ' VOD catalogs can be much larger than live categories. Bound the file
    ' before reading or parsing it, and keep the transfer off the render thread.
    maxBytes = 8388608
    path = "tmp:/vod-" + CreateObject("roDeviceInfo").GetRandomUUID() + ".json"
    transfer = CreateObject("roUrlTransfer")
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
    while not m.top.cancelRequested and timer.TotalMilliseconds() < timeoutMs
        event = wait(150, port)
        if Type(event) = "roUrlEvent" and event.GetSourceIdentity() = transfer.GetIdentity()
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
    result = {error: "Could not load movies from the provider", httpCode: code}
    if m.top.cancelRequested
        result.error = "Search cancelled"
    else if tooLarge or size > maxBytes
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
    else if code = 429
        result.error = "Provider is busy. Try again shortly."
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
    if m.top.cancelRequested then return
    m.top.error = message
    m.top.status = "error"
end sub
