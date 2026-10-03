' Main scene logic for handling UI and initializing tasks
sub init()
    m.background = m.top.findNode("background")
    m.spinner = m.top.findNode("spinner")
    m.spinnerAnim = m.top.findNode("loadSpinnerAnim")
    m.statusLabel = m.top.findNode("statusLabel")
    m.errorLabel = m.top.findNode("errorLabel")
    m.errorHintLabel = m.top.findNode("errorHintLabel")
    m.brandGroup = m.top.findNode("brandGroup")
    
    m.channelsScreen = m.top.findNode("channelsScreen")
    m.playerScreen = m.top.findNode("playerScreen")
    m.searchScreen = m.top.findNode("searchScreen")
    m.settingsScreen = m.top.findNode("settingsScreen")
    
    m.onboardingGroup = m.top.findNode("onboardingGroup")
    m.onboardingOk = m.top.findNode("onboardingOk")
    m.onboardingDialog = invalid
    m.onboardingDraft = ""
    m.exitDialog = invalid
    
    m.channelsScreen.observeField("playRequest", "onPlayRequest")
    m.channelsScreen.observeField("openSearch", "onOpenSearch")
    m.channelsScreen.observeField("openSettings", "onOpenSettings")
    m.channelsScreen.observeField("catalogUpdate", "onCatalogUpdate")
    
    m.playerScreen.observeField("exitRequested", "onPlayerExit")
    
    m.searchScreen.observeField("exitRequested", "onChildScreenExit")
    m.searchScreen.observeField("playRequest", "onPlayRequest")
    
    m.settingsScreen.observeField("exitRequested", "onChildScreenExit")
    ' Observe the TRIGGER, not the payload: repeating the same action leaves the
    ' string unchanged and a field observer only fires on change. Exactly one
    ' observer here -- watching both fields would handle every action twice.
    m.settingsScreen.observeField("actionCommand", "onSettingsAction")

    ' EPG state. epgFailed drives the About text; epgNoticeShown limits the toast to
    ' once per session (epgRefreshTimer retries hourly, forever); epgUserInitiated
    ' forces a toast for the one load the user explicitly asked for.
    m.epgFailed = false
    m.epgNoticeShown = false
    m.epgUserInitiated = false
    m.epgGeneratedText = ""
    m.epgAutomatic = false
    m.epgOverrideUrl = ""
    m.epgProviderRunning = false
    m.epgPendingChannels = []
    m.epgPendingIds = {}

    m.onboardingOk.observeField("buttonSelected", "openOnboardingKeyboard")
    
    m.epgRefreshTimer = m.top.findNode("epgRefreshTimer")
    m.epgRefreshTimer.observeField("fire", "onEpgRefresh")
    
    m.top.findNode("nowTimer").observeField("fire", "onNowTick")
    m.top.findNode("nowTimer").control = "start"
    
    theme = getTheme()
    if theme <> invalid
        m.background.color = theme.colorBg
        m.statusLabel.color = theme.colorTextDim
        m.errorLabel.color = theme.colorText
        m.errorHintLabel.color = theme.colorTextDim
    end if
    
    m.top.setFocus(true)
    
    m.playlistResultCache = invalid
    
    if m.global.epg = invalid then m.global.addField("epg", "assocarray", false)
    if m.global.epgReady = invalid then m.global.addField("epgReady", "boolean", false)
    if m.global.theme = invalid then m.global.addField("theme", "assocarray", false)
    m.global.theme = getTheme()
    if m.global.nowSec = invalid then m.global.addField("nowSec", "integer", false)
    m.global.nowSec = CreateObject("roDateTime").AsSeconds()

    runConfigTask()
end sub

sub runConfigTask()
    m.configTask = CreateObject("roSGNode", "ConfigTask")
    m.configTask.observeField("config", "onConfigLoaded")
    m.configTask.observeField("error", "onConfigError")
    m.configTask.control = "RUN"
end sub

sub onConfigLoaded()
    config = m.configTask.config
    m.configCache = config
    startDashboard()

    url = ""
    sec = CreateObject("roRegistrySection", "settings")
    ' A personalized package can replace an old saved URL once. Subsequent launches
    ' keep user edits instead of repeatedly overwriting the registry.
    if config <> invalid and config.importRevision <> invalid and config.playlistUrl <> invalid
        if config.importRevision <> "" and config.playlistUrl <> ""
            if sec.Read("importRevision") <> config.importRevision
                sec.Write("playlistUrl", config.playlistUrl)
                sec.Write("importRevision", config.importRevision)
                sec.Flush()
            end if
        end if
    end if
    if sec.Exists("playlistUrl")
        url = sec.Read("playlistUrl")
    end if
    
    if url = "" and config <> invalid and config.playlistUrl <> invalid and config.playlistUrl <> ""
        url = config.playlistUrl
    end if
    
    if url <> ""
        startPlaylistLoad(url, false)
    else
        showOnboarding()
    end if
end sub

sub startPlaylistLoad(url as string, forceReload as boolean)
    if m.currentUrl <> url then m.dashboardSourceRevision = dashboardUuid()
    showLoading("Loading playlist…")
    m.currentUrl = url
    useLiveApi = false
    if m.configCache <> invalid and m.configCache.xtream <> invalid
        useLiveApi = (url = m.configCache.playlistUrl)
    end if
    if useLiveApi
        showLoading("Loading live channels…")
        m.playlistTask = CreateObject("roSGNode", "XtreamTask")
        m.playlistTask.accountConfig = m.configCache.xtream
    else
        m.playlistTask = CreateObject("roSGNode", "PlaylistTask")
    end if
    m.playlistTask.playlistUrl = url
    m.playlistTask.forceReload = forceReload
    m.playlistTask.observeField("status", "onPlaylistStatus")
    if not useLiveApi and m.configCache <> invalid and m.configCache.extraPlaylists <> invalid
        m.playlistTask.extraPlaylists = m.configCache.extraPlaylists
    end if
    m.playlistTask.control = "RUN"
end sub

sub onPlaylistStatus()
    status = m.playlistTask.status
    
    if status = "ok" or status = "cache"
        res = m.playlistTask.result
        if res <> invalid
            resetDashboardCatalog(res)
            m.playlistResultCache = res
            showChannels(res)
            
            configureEpg(res)
        end if
    else if status = "error"
        err = m.playlistTask.error
        if err = invalid then err = "Unknown error"
        showError(err)
    end if
end sub

sub onConfigError()
    showError("config.json not found")
end sub

sub hideAllScreens()
    m.spinner.visible = false
    m.spinnerAnim.control = "stop"
    m.statusLabel.visible = false
    m.errorLabel.visible = false
    m.errorHintLabel.visible = false
    m.brandGroup.visible = false
    
    m.channelsScreen.visible = false
    m.playerScreen.visible = false
    m.searchScreen.visible = false
    m.settingsScreen.visible = false
    m.onboardingGroup.visible = false
end sub

sub showLoading(text as string)
    hideAllScreens()
    m.brandGroup.visible = true
    m.spinner.visible = true
    m.spinnerAnim.control = "start"
    m.statusLabel.visible = true
    m.statusLabel.text = text
end sub

sub showError(errText as string)
    hideAllScreens()
    m.brandGroup.visible = true
    m.errorLabel.visible = true
    m.errorLabel.text = errText
    m.errorHintLabel.visible = true
end sub

sub showOnboarding()
    hideAllScreens()
    m.onboardingGroup.visible = true
    m.onboardingOk.setFocus(true)
    openOnboardingKeyboard()
end sub

sub openOnboardingKeyboard()
    if m.onboardingDialog <> invalid then return

    ' The system dialog lays out its keyboard and buttons together at the current
    ' display resolution. Do not position a standalone keyboard by a fixed offset.
    dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
    dialog.title = "Enter playlist URL"
    dialog.buttons = ["Save and continue", "Cancel"]
    dialog.text = m.onboardingDraft
    ' Provider URLs can be much longer than the default text field allows.
    dialog.textEditBox.maxTextLength = 4096
    ' URL credentials should not introduce voice entry as a new input path.
    dialog.textEditBox.voiceEnabled = false
    dialog.observeField("buttonSelected", "onOnboardingButton")
    dialog.observeField("wasClosed", "onOnboardingClosed")
    m.onboardingDialog = dialog
    m.top.dialog = dialog
end sub

sub onOnboardingButton(event as object)
    if m.onboardingDialog = invalid then return
    if event.getData() <> 0
        m.onboardingDialog.close = true
        return
    end if

    url = m.onboardingDialog.text.Trim()
    if url = ""
        m.onboardingDialog.title = "Please enter a playlist URL"
        return
    end if

    sec = CreateObject("roRegistrySection", "settings")
    sec.Write("playlistUrl", url)
    sec.Flush()
    m.onboardingDraft = url
    ' Hide setup first so a close event cannot steal focus from the next screen.
    m.onboardingGroup.visible = false
    m.onboardingDialog.close = true
    startPlaylistLoad(url, false)
end sub

sub onOnboardingClosed()
    if m.onboardingDialog = invalid then return
    m.onboardingDraft = m.onboardingDialog.text
    m.onboardingDialog = invalid
    ' Cancel/Back keep the draft and leave an explicit way to reopen the keyboard.
    if m.onboardingGroup.visible then m.onboardingOk.setFocus(true)
end sub

sub showChannels(res as object)
    hideAllScreens()
    m.channelsScreen.visible = true
    if res.providerMode = true and m.configCache <> invalid
        m.channelsScreen.accountConfig = m.configCache.xtream
    end if
    m.channelsScreen.playlistResult = res
    m.channelsScreen.setFocus(true)
end sub

sub onCatalogUpdate(event as object)
    update = event.getData()
    if update = invalid or update.channels = invalid then return
    if m.playlistResultCache = invalid then return
    m.playlistResultCache.channels = update.channels
    rememberDashboardChannels(update.channels)
    if update.newChannels <> invalid then queueProviderEpg(update.newChannels)
end sub

sub onPlayRequest(event as object)
    req = event.getData()
    if req <> invalid and req.channels <> invalid
        if m.epgAutomatic and req.index <> invalid and req.index >= 0 and req.index < req.channels.Count()
            queueProviderEpg([req.channels[req.index]])
        end if
        hideAllScreens()
        m.playerScreen.visible = true
        
        m.playerScreen.playlist = req.channels
        m.playerScreen.startIndex = req.index
        m.playerScreen.playCommand = not m.playerScreen.playCommand
        
        m.playerScreen.setFocus(true)
    end if
end sub

sub onPlayerExit()
    hideAllScreens()
    m.channelsScreen.visible = true
    m.channelsScreen.restoreFocus = not m.channelsScreen.restoreFocus
end sub

sub onOpenSearch()
    m.searchScreen.providerMode = false
    if m.playlistResultCache <> invalid
        m.searchScreen.channels = m.playlistResultCache.channels
        if m.playlistResultCache.providerMode = true and m.configCache <> invalid and m.configCache.xtream <> invalid
            m.searchScreen.providerMode = true
            m.searchScreen.accountConfig = m.configCache.xtream
        end if
    end if
    hideAllScreens()
    m.searchScreen.visible = true
end sub

sub onOpenSettings()
    info = {
        playlistUrl: m.currentUrl,
        channelCount: 0,
        fetchedAt: "",
        source: "",
        epgUrl: "",
        epgAutomatic: m.epgAutomatic
    }
    if m.playlistResultCache <> invalid
        if m.playlistResultCache.channels <> invalid
            info.channelCount = m.playlistResultCache.channels.Count()
        end if
        info.fetchedAt = fmtEpochLocal(m.playlistResultCache.fetchedAt)
        info.source = m.playlistResultCache.source
    end if
    info.epgUrl = m.epgOverrideUrl
    if m.epgCount <> invalid then info.epgCount = m.epgCount
    info.epgFailed = m.epgFailed
    info.epgGeneratedText = m.epgGeneratedText

    m.settingsScreen.info = info
    hideAllScreens()
    m.settingsScreen.visible = true
end sub

sub onChildScreenExit()
    hideAllScreens()
    m.channelsScreen.visible = true
    m.channelsScreen.restoreFocus = not m.channelsScreen.restoreFocus
end sub

sub onSettingsAction()
    action = m.settingsScreen.action
    if action = "refresh"
        startPlaylistLoad(m.currentUrl, true)
    else if action = "clearCache"
        startPlaylistLoad(m.currentUrl, false)
    else if action = "urlChanged"
        sec = CreateObject("roRegistrySection", "settings")
        sec.Delete("dashboardProvider")
        sec.Flush()
        startPlaylistLoad(m.settingsScreen.newUrl, false)
    else if action = "epgChanged"
        ' The user just asked for this load, so report its outcome even if a toast
        ' has already been shown this session.
        m.epgUserInitiated = true
        configureEpg(m.playlistResultCache)
    end if
end sub

sub configureEpg(res as object)
    m.epgAutomatic = false
    m.epgOverrideUrl = ""
    epgUrl = ""
    sec = CreateObject("roRegistrySection", "settings")
    if sec.Exists("epgUrl") then epgUrl = sec.Read("epgUrl").Trim()
    if epgUrl = "" and m.configCache <> invalid and m.configCache.epgUrl <> invalid
        epgUrl = m.configCache.epgUrl.Trim()
    end if

    if epgUrl <> ""
        m.epgOverrideUrl = epgUrl
        startEpgLoad(epgUrl)
    else if res <> invalid and res.providerMode = true and m.configCache <> invalid and m.configCache.xtream <> invalid
        m.epgAutomatic = true
        m.currentEpgUrl = ""
        m.epgPendingChannels = []
        m.epgPendingIds = {}
        if not m.epgProviderRunning then startProviderEpgLoad([])
    else
        m.currentEpgUrl = ""
    end if
end sub

sub startEpgLoad(url as string)
    m.currentEpgUrl = url
    m.urlEpgTask = CreateObject("roSGNode", "EpgTask")
    m.urlEpgTask.epgUrl = url
    m.urlEpgTask.observeField("status", "onUrlEpgStatus")
    m.urlEpgTask.control = "RUN"
    
    m.epgRefreshTimer.control = "start"
end sub

sub onUrlEpgStatus()
    if m.urlEpgTask = invalid then return
    status = m.urlEpgTask.status
    if status = "ok" or status = "cache"
        acceptEpgResult(m.urlEpgTask.result)
    else if status = "error"
        ' EPG is an enhancement, not a requirement: channels must keep playing. So no
        ' showError() here -- that hides the grid. A log line, a durable record in
        ' About, and at most one toast.
        reason = m.urlEpgTask.error
        if reason = invalid or reason = "" then reason = "unknown"
        print "MainScene: EPG unavailable (" + reason + ")"

        m.epgFailed = true
        m.epgCount = invalid

        if m.epgUserInitiated or not m.epgNoticeShown
            showNotice("Guide unavailable")
            m.epgNoticeShown = true
        end if
    end if
    ' Consumed either way: it marks one specific load, not a standing mode.
    m.epgUserInitiated = false
end sub

sub queueProviderEpg(channels as object)
    if not m.epgAutomatic or channels = invalid then return
    for each ch in channels
        streamId = ""
        epgId = ""
        if ch.providerStreamId <> invalid then streamId = ch.providerStreamId
        if ch.tvgId <> invalid then epgId = ch.tvgId
        if streamId <> "" and epgId <> "" and not m.epgPendingIds.DoesExist(streamId)
            m.epgPendingIds[streamId] = true
            m.epgPendingChannels.Push(ch)
        end if
    end for
    if not m.epgProviderRunning and m.epgPendingChannels.Count() > 0
        channelsToLoad = m.epgPendingChannels
        m.epgPendingChannels = []
        m.epgPendingIds = {}
        startProviderEpgLoad(channelsToLoad)
    end if
end sub

sub startProviderEpgLoad(channels as object)
    if not m.epgAutomatic or m.epgProviderRunning then return
    m.epgProviderRunning = true
    m.providerEpgTask = CreateObject("roSGNode", "EpgTask")
    m.providerEpgTask.providerConfig = m.configCache.xtream
    m.providerEpgTask.providerChannels = channels
    m.providerEpgTask.observeField("status", "onProviderEpgStatus")
    m.providerEpgTask.control = "RUN"
    m.epgRefreshTimer.control = "start"
end sub

sub onProviderEpgStatus()
    if m.providerEpgTask = invalid then return
    status = m.providerEpgTask.status
    if status <> "ok" and status <> "cache" and status <> "error" then return
    if m.epgAutomatic
        if status = "ok" or status = "cache"
            acceptEpgResult(m.providerEpgTask.result)
        else
            reason = m.providerEpgTask.error
            if reason = invalid or reason = "" then reason = "unknown"
            print "MainScene: automatic EPG unavailable (" + reason + ")"
            m.epgFailed = true
            if m.epgUserInitiated or not m.epgNoticeShown
                showNotice("Automatic guide unavailable")
                m.epgNoticeShown = true
            end if
        end if
    end if
    m.epgUserInitiated = false
    m.epgProviderRunning = false
    m.providerEpgTask = invalid
    if m.epgAutomatic and m.epgPendingChannels.Count() > 0
        channelsToLoad = m.epgPendingChannels
        m.epgPendingChannels = []
        m.epgPendingIds = {}
        startProviderEpgLoad(channelsToLoad)
    end if
end sub

sub acceptEpgResult(res as object)
    if res = invalid or res.epg = invalid then return
    if m.global.epg = invalid then m.global.addField("epg", "assocarray", false)
    if m.global.epgReady = invalid then m.global.addField("epgReady", "boolean", false)
    m.global.epg = res.epg
    m.global.epgReady = not m.global.epgReady
    m.epgCount = res.epg.Count()
    if res.generated <> invalid
        m.epgGenerated = res.generated
        m.epgGeneratedText = fmtEpochLocal(res.generated)
    end if
    m.epgFailed = false
end sub

' Best-effort toast on whichever screen is in front. MainScene owns no toast of its
' own (each screen has a private one), so it routes via notice + noticeCommand.
' PlayerScreen is deliberately excluded: never interrupt playback for a guide message.
sub showNotice(msg as string)
    target = invalid
    if m.settingsScreen.visible
        target = m.settingsScreen
    else if m.channelsScreen.visible
        target = m.channelsScreen
    end if
    if target = invalid then return
    target.notice = msg
    target.noticeCommand = not target.noticeCommand
end sub

sub showExitConfirmation()
    if m.exitDialog <> invalid then return
    dialog = CreateObject("roSGNode", "StandardMessageDialog")
    dialog.title = "Exit IPTV Player?"
    dialog.message = ["Are you sure you want to exit?"]
    dialog.buttons = ["Exit", "Cancel"]
    dialog.observeField("buttonSelected", "onExitDialogButton")
    dialog.observeField("wasClosed", "onExitDialogClosed")
    m.exitDialog = dialog
    m.top.dialog = dialog
end sub

sub onExitDialogButton(event as object)
    if m.exitDialog = invalid then return
    if event.getData() = 0
        m.exitDialog.close = true
        m.top.exitApp = not m.top.exitApp
    else
        m.exitDialog.close = true
    end if
end sub

sub onExitDialogClosed()
    m.exitDialog = invalid
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if press
        if key = "back"
            if m.errorLabel.visible
                if m.currentUrl <> invalid and not m.currentUrl.StartsWith("xtream://")
                    m.onboardingDraft = m.currentUrl
                else
                    m.onboardingDraft = ""
                end if
                showOnboarding()
                handled = true
            else if m.channelsScreen.visible
                showExitConfirmation()
                handled = true
            end if
        else if key = "OK"
            if m.errorLabel.visible
                if m.currentUrl <> invalid and m.currentUrl <> ""
                    startPlaylistLoad(m.currentUrl, false)
                    handled = true
                else
                    runConfigTask()
                    handled = true
                end if
            end if
        end if
    end if
    return handled
end function

' epoch (int/float/string) -> "YYYY-MM-DD HH:MM" in local time; otherwise ""
function fmtEpochLocal(v as dynamic) as string
    if v = invalid then return ""
    if GetInterface(v, "ifString") <> invalid then return v
    sec = 0
    if GetInterface(v, "ifInt") <> invalid
        sec = v
    else if GetInterface(v, "ifFloat") <> invalid or GetInterface(v, "ifDouble") <> invalid
        sec = Int(v)
    else
        return ""
    end if
    dt = CreateObject("roDateTime")
    dt.FromSeconds(sec)
    dt.ToLocalTime()
    y = dt.GetYear().ToStr()
    mo = dt.GetMonth().ToStr()
    if mo.Len() = 1 then mo = "0" + mo
    d = dt.GetDayOfMonth().ToStr()
    if d.Len() = 1 then d = "0" + d
    h = dt.GetHours().ToStr()
    if h.Len() = 1 then h = "0" + h
    mn = dt.GetMinutes().ToStr()
    if mn.Len() = 1 then mn = "0" + mn
    return y + "-" + mo + "-" + d + " " + h + ":" + mn
end function

sub onEpgRefresh()
    if m.epgAutomatic
        if m.playlistResultCache <> invalid and m.playlistResultCache.channels <> invalid
            queueProviderEpg(m.playlistResultCache.channels)
        end if
    else if m.currentEpgUrl <> invalid and m.currentEpgUrl <> ""
        startEpgLoad(m.currentEpgUrl)
    end if
end sub

sub onNowTick()
    m.global.nowSec = CreateObject("roDateTime").AsSeconds()
end sub
