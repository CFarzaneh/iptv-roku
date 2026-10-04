' Included by MainScene: all UI mutations remain on the render thread.
sub startDashboard()
    if m.dashboardTask <> invalid then return
    if not CreateObject("roFileSystem").Exists("pkg:/source/dashboard.json") then return
    m.dashboardSession = dashboardUuid()
    m.dashboardSourceRevision = dashboardUuid()
    m.dashboardCatalogRevision = dashboardUuid()
    m.dashboardKnownChannels = {}
    m.dashboardSeen = {}
    m.dashboardSeenOrder = []
    m.dashboardCatalogCache = {}
    m.dashboardTask = CreateObject("roSGNode", "DashboardTask")
    m.dashboardTask.observeField("incoming", "onDashboardIncoming")
    m.playerScreen.observeField("dashboardSnapshot", "onDashboardPlayback")
    m.top.findNode("dashboardTimer").observeField("fire", "publishDashboardSnapshot")
    m.top.findNode("dashboardTimer").control = "start"
    publishDashboardSnapshot()
    m.dashboardTask.control = "RUN"
end sub

sub resetDashboardCatalog(res as object)
    m.dashboardCatalogRevision = dashboardUuid()
    m.dashboardKnownChannels = {}
    m.dashboardCatalogCache = {}
    if res.providerMode <> true then dashboardAssignM3uIds(res.channels)
    rememberDashboardChannels(res.channels)
    publishDashboardSnapshot()
end sub

sub rememberDashboardChannels(channels as object)
    if m.dashboardKnownChannels = invalid then m.dashboardKnownChannels = {}
    for each channel in channels
        key = dashboardChannelId(channel)
        if key <> "" and m.dashboardKnownChannels.Count() < 10000 then m.dashboardKnownChannels[key] = channel
    end for
end sub

sub publishDashboardSnapshot()
    if m.dashboardTask = invalid then return
    playback = m.playerScreen.dashboardSnapshot
    if playback = invalid
        playback = { state: "idle", playbackRevision: 0, channel: invalid, metrics: dashboardEmptyMetrics() }
    end if
    providerType = "none"
    if m.currentUrl <> invalid and m.currentUrl <> ""
        providerType = "m3u"
        if m.configCache <> invalid and m.configCache.xtream <> invalid
            if m.currentUrl = m.configCache.playlistUrl then providerType = "xtream"
        end if
    end if
    m.dashboardTask.snapshot = {
        appSessionId: m.dashboardSession,
        sourceRevision: m.dashboardSourceRevision,
        catalogRevision: m.dashboardCatalogRevision,
        playbackRevision: playback.playbackRevision,
        state: playback.state,
        channel: playback.channel,
        metrics: playback.metrics,
        appVersion: CreateObject("roAppInfo").GetVersion(),
        osVersion: CreateObject("roDeviceInfo").GetVersion(),
        provider: { type: providerType, configured: providerType <> "none" }
    }
end sub

sub dashboardReply(command as object, status as string, code = "NONE" as string, data = invalid as dynamic)
    reply = { commandId: command.commandId, status: status, code: code }
    if data <> invalid then reply.data = data
    m.dashboardTask.outgoing = reply
end sub

sub onDashboardIncoming(event as object)
    command = event.GetData()
    if command = invalid or command.commandId = invalid then return
    if command.appSessionId <> m.dashboardSession or command.expiresAt <= dashboardNow()
        dashboardReply(command, "stale", "STALE")
        return
    end if
    if m.dashboardSeen.DoesExist(command.commandId) then return
    m.dashboardSeen[command.commandId] = true
    m.dashboardSeenOrder.Push(command.commandId)
    if m.dashboardSeenOrder.Count() > 100 then m.dashboardSeen.Delete(m.dashboardSeenOrder.Shift())
    dashboardReply(command, "received")
    if command.type = "catalog"
        dashboardBrowse(command)
    else if command.type = "changeChannel"
        dashboardTune(command)
    else if command.type = "providerConfig"
        if m.dashboardValidation <> invalid
            dashboardReply(command, "failed", "UNAVAILABLE")
            return
        end if
        m.dashboardProviderCommand = command
        m.dashboardValidation = CreateObject("roSGNode", "ProviderValidationTask")
        m.dashboardValidation.candidate = command
        m.dashboardValidation.observeField("result", "onDashboardProviderValidated")
        m.dashboardValidation.control = "RUN"
    end if
end sub

sub dashboardBrowse(command as object)
    res = m.playlistResultCache
    if res = invalid
        dashboardReply(command, "failed", "UNAVAILABLE")
        return
    end if
    if res.providerMode = true
        cacheKey = command.kind + "|" + command.categoryId + "|" + command.query
        cached = m.dashboardCatalogCache[cacheKey]
        if cached <> invalid
            dashboardSendCatalog(command, cached)
            return
        end if
        if m.dashboardCatalogTask <> invalid
            dashboardReply(command, "failed", "UNAVAILABLE")
            return
        end if
        if command.kind = "channels" and command.categoryId = ""
            dashboardReply(command, "failed", "UNAVAILABLE")
            return
        end if
        task = CreateObject("roSGNode", "XtreamTask")
        task.accountConfig = m.configCache.xtream
        if command.kind = "channels"
            task.categoryId = command.categoryId
            for each category in res.categories
                if category.providerId = command.categoryId then task.categoryName = category.title
            end for
        else if command.kind = "search"
            task.searchQuery = command.query
        end if
        m.dashboardCatalogTask = task
        m.dashboardCatalogCommand = command
        m.dashboardCatalogKey = cacheKey
        m.dashboardCatalogSource = m.dashboardSourceRevision
        task.observeField("status", "onDashboardCatalogLoaded")
        task.control = "RUN"
    else
        dashboardSendCatalog(command, res)
    end if
end sub

sub onDashboardCatalogLoaded()
    task = m.dashboardCatalogTask
    if task = invalid then return
    if task.status <> "ok" and task.status <> "error" then return
    command = m.dashboardCatalogCommand
    if m.dashboardSourceRevision <> m.dashboardCatalogSource or command.expiresAt <= dashboardNow()
        dashboardReply(command, "stale", "STALE")
    else if task.status = "error"
        dashboardReply(command, "failed", "PROVIDER_ERROR")
    else
        if m.dashboardCatalogCache.Count() >= 4 then m.dashboardCatalogCache = {}
        m.dashboardCatalogCache[m.dashboardCatalogKey] = task.result
        dashboardSendCatalog(command, task.result)
    end if
    m.dashboardCatalogTask = invalid
    m.dashboardCatalogCommand = invalid
end sub

sub dashboardSendCatalog(command as object, res as object)
    data = { sourceRevision: m.dashboardSourceRevision, catalogRevision: m.dashboardCatalogRevision }
    if command.kind = "categories"
        data.categories = []
        for each category in res.categories
            key = dashboardText(category.providerId)
            if key = "" then key = dashboardText(category.title)
            if data.categories.Count() < 2000 then data.categories.Push({ id: key.Left(200), name: dashboardText(category.title).Left(200) })
        end for
    else
        matches = []
        for each channel in res.channels
            include = true
            if res.providerMode <> true
                if command.kind = "channels" and command.categoryId <> "All" then include = (channel.group = command.categoryId)
                if command.kind = "search" then include = (LCase(channel.name).Instr(LCase(command.query)) >= 0)
            end if
            if include then matches.Push(channel)
        end for
        data.channels = []
        m.dashboardPlayContext = matches
        data.offset = command.offset
        data.total = matches.Count()
        data.incomplete = false
        if res.totalMatches <> invalid then data.incomplete = (res.totalMatches > matches.Count())
        lastIndex = command.offset + command.limit - 1
        if lastIndex >= matches.Count() then lastIndex = matches.Count() - 1
        for i = command.offset to lastIndex
            channel = matches[i]
            key = dashboardChannelId(channel)
            if key <> ""
                data.channels.Push(dashboardChannel(channel))
                rememberDashboardChannels([channel])
            end if
        end for
    end if
    dashboardReply(command, "ok", "NONE", data)
end sub

sub dashboardTune(command as object)
    playback = m.playerScreen.dashboardSnapshot
    revision = 0
    if playback <> invalid then revision = playback.playbackRevision
    if command.sourceRevision <> m.dashboardSourceRevision or command.catalogRevision <> m.dashboardCatalogRevision or command.expectedPlaybackRevision <> revision
        dashboardReply(command, "stale", "STALE")
        return
    end if
    channel = m.dashboardKnownChannels[command.streamId]
    if channel = invalid
        dashboardReply(command, "failed", "INVALID_CHANNEL")
        return
    end if
    if m.dashboardTuneCommand <> invalid then dashboardReply(m.dashboardTuneCommand, "stale", "STALE")
    m.dashboardTuneCommand = command
    hideAllScreens()
    m.playerScreen.visible = true
    m.playerScreen.dashboardCommandId = command.commandId
    context = [channel]
    selectedIndex = 0
    if m.dashboardPlayContext <> invalid
        for i = 0 to m.dashboardPlayContext.Count() - 1
            if dashboardChannelId(m.dashboardPlayContext[i]) = command.streamId
                context = m.dashboardPlayContext
                selectedIndex = i
                exit for
            end if
        end for
    end if
    m.playerScreen.playlist = context
    m.playerScreen.startIndex = selectedIndex
    m.playerScreen.playCommand = not m.playerScreen.playCommand
    m.playerScreen.setFocus(true)
    dashboardReply(command, "tuning")
end sub

sub onDashboardPlayback(event as object)
    playback = event.GetData()
    if m.dashboardTuneCommand <> invalid
        if playback.commandId <> m.dashboardTuneCommand.commandId
            dashboardReply(m.dashboardTuneCommand, "stale", "STALE")
            m.dashboardTuneCommand = invalid
        else if playback.state = "playing"
            dashboardReply(m.dashboardTuneCommand, "playing")
            m.dashboardTuneCommand = invalid
        else if playback.state = "error"
            dashboardReply(m.dashboardTuneCommand, "failed", "PLAYBACK_ERROR")
            m.dashboardTuneCommand = invalid
        end if
    end if
    publishDashboardSnapshot()
end sub

sub onDashboardProviderValidated()
    task = m.dashboardValidation
    command = m.dashboardProviderCommand
    m.dashboardValidation = invalid
    m.dashboardProviderCommand = invalid
    if not task.result.ok
        dashboardReply(command, "failed", "PROVIDER_ERROR")
        return
    end if
    if command.expiresAt <= dashboardNow()
        dashboardReply(command, "stale", "STALE")
        return
    end if
    candidate = { providerType: command.providerType, server: command.server, username: command.username, password: command.password }
    sec = CreateObject("roRegistrySection", "settings")
    previous = sec.Read("dashboardProvider")
    if not sec.Write("dashboardProvider", FormatJson(candidate))
        dashboardReply(command, "failed", "SAVE_FAILED")
        return
    end if
    if not sec.Flush()
        sec.Write("dashboardProvider", previous)
        sec.Flush()
        dashboardReply(command, "failed", "SAVE_FAILED")
        return
    end if
    ' Keep the current playback/catalog coherent. Apply the saved account at next app launch.
    dashboardReply(command, "saved")
    ' A fresh, unconfigured sideload can load its first account without a Roku-side step.
    if m.currentUrl = invalid or m.currentUrl = "" then runConfigTask()
end sub
