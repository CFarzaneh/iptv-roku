' PlayerScreen
sub init()
    m.video = m.top.findNode("video")
    m.spinner = m.top.findNode("spinner")
    m.spinnerAnim = m.top.findNode("playSpinnerAnim")
    m.loadingLabel = m.top.findNode("loadingLabel")
    
    m.overlayGroup = m.top.findNode("overlayGroup")
    m.overlayName = m.top.findNode("overlayName")
    m.overlayGroupLabel = m.top.findNode("overlayGroupLabel")
    m.overlayTime = m.top.findNode("overlayTime")
    m.overlayEpg = m.top.findNode("overlayEpg")
    
    m.miniBanner = m.top.findNode("miniBanner")
    m.miniBannerLabel = m.top.findNode("miniBannerLabel")
    
    m.errorDialog = m.top.findNode("errorDialog")
    m.errorMsg = m.top.findNode("errorMsg")
    m.errorOptions = m.top.findNode("errorOptions")
    
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    
    m.overlayTimer = m.top.findNode("overlayTimer")
    m.miniBannerTimer = m.top.findNode("miniBannerTimer")
    m.toastTimer = m.top.findNode("toastTimer")
    m.clockTimer = m.top.findNode("clockTimer")
    m.okTimer = m.top.findNode("okTimer")
    
    m.zapLine2 = m.top.findNode("zapLine2")
    m.zapUntil = m.top.findNode("zapUntil")
    m.zapProgress = m.top.findNode("zapProgress")

    m.zapperPanel = m.top.findNode("zapperPanel")
    m.zapperGrid = m.top.findNode("zapperGrid")
    m.zapperTimer = m.top.findNode("zapperTimer")
    
    m.video.observeField("state", "onVideoStateChange")
    m.video.observeField("availableAudioTracks", "onAvailableAudioTracks")
    m.overlayTimer.observeField("fire", "hideOverlay")
    m.miniBannerTimer.observeField("fire", "hideMiniBanner")
    m.toastTimer.observeField("fire", "hideToast")
    m.clockTimer.observeField("fire", "updateClock")
    m.okTimer.observeField("fire", "onOkLongPress")
    
    m.zapperGrid.observeField("itemSelected", "onZapperSelected")
    m.zapperGrid.observeField("itemFocused", "onZapperFocused")
    m.zapperTimer.observeField("fire", "closeZapper")
    
    m.okLongFired = false
    
    m.errorOptions.observeField("itemSelected", "onErrorOptionSelected")
    
    theme = getTheme()
    ' Cached here, not fetched per zap: getTheme() builds an 11-key AA on every call
    ' and showMiniBanner is on the channel-change hot path (GEMINI.md #17).
    m.theme = theme
    if theme <> invalid
        m.overlayName.color = theme.colorText
        ' The category is a fact, not an accent. It was rendering in focusBright,
        ' which made green mean four different things across the app.
        m.overlayGroupLabel.color = theme.colorTextDim
        m.overlayTime.color = theme.colorText
        m.miniBannerLabel.color = theme.colorText
        m.errorDialog.color = theme.colorSurface
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.errorOptions.color = theme.colorTextDim
        m.errorOptions.focusedColor = theme.colorOnAccent
    end if
    
    m.currentIndex = -1

    ' Roku rejects some otherwise playable HE-AAC streams when their ADTS headers
    ' advertise the Main profile. Keep the local repair dormant unless that exact
    ' decoder error occurs. Once detected, remember the channel for this app session
    ' so later visits go straight through the repaired path.
    m.audioRepairTask = invalid
    m.audioRepairKnown = {}
    m.audioRepairPendingIndex = -1
    m.audioRepairActive = false
    m.audioRepairPort = 8765
    m.audioRepairSession = 0
    initDashboardTelemetry()
end sub

sub addErrorOption(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

sub onPlayCommand()
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 then return
    idx = m.top.startIndex
    if idx = invalid or idx < 0 or idx >= m.top.playlist.Count() then idx = 0
    playIndex(idx)
end sub

sub playIndex(idx as integer)
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 return
    if idx < 0 or idx >= m.top.playlist.Count() return
    
    m.currentIndex = idx
    channel = m.top.playlist[idx]
    dashboardBeginTune(channel)
    
    if not IsAdultGroup(channel.group)
        PushRecent(channel.name)
    end if
    
    m.errorDialog.visible = false
    m.lastPlaybackError = ""
    
    ' Set the loading caption HERE, not only from onVideoStateChange. That observer
    ' fires on a state CHANGE, and a zap while the video is already "buffering" does
    ' not change the state -- so the caption kept naming the previous channel during a
    ' fast surf. Same class as the Settings action field that only fired once.
    m.loadingLabel.text = "Loading: " + channel.name

    showMiniBanner(channel)
    updateOverlayData(channel)
    focusPlayer()

    key = audioRepairKey(channel)
    if key <> "" and m.audioRepairKnown.DoesExist(key)
        print "[MEDIA] using remembered local audio repair"
        startAudioRepair(idx)
    else
        m.audioRepairPendingIndex = -1
        playChannelUrl(channel, channel.url, false)
    end if
end sub

sub playChannelUrl(channel as object, url as string, repaired as boolean)
    node = CreateObject("roSGNode", "ContentNode")
    node.title = channel.name
    node.url = url
    if repaired
        node.streamFormat = "hls"
    else if channel.streamFormat <> invalid and channel.streamFormat <> ""
        node.streamFormat = channel.streamFormat
    else
        node.streamFormat = "hls"
    end if
    node.live = true
    ' This provider rejects generic/default clients with HTTP 403, while its API,
    ' browser clients, and a Roku-style User-Agent receive the same HLS playlist.
    ' Put the header on the ContentNode so the Video node applies it to both the
    ' manifest and media-segment requests (not just the catalog API request).
    node.HttpHeaders = ["User-Agent:Mozilla/5.0"]

    m.audioRepairActive = repaired
    m.video.mute = false
    m.video.content = node
    m.video.control = "play"
end sub

sub onVideoStateChange()
    state = m.video.state
    if state = "buffering"
        m.spinner.visible = true
        m.spinnerAnim.control = "start"
        m.loadingLabel.visible = true
        if m.currentIndex >= 0 and m.top.playlist <> invalid
            if m.audioRepairActive
                m.loadingLabel.text = "Repairing audio: " + m.top.playlist[m.currentIndex].name
            else
                m.loadingLabel.text = "Loading: " + m.top.playlist[m.currentIndex].name
            end if
        else
            m.loadingLabel.text = "Loading…"
        end if
    else if state = "playing"
        m.spinner.visible = false
        m.spinnerAnim.control = "stop"
        m.loadingLabel.visible = false
    else if state = "error"
        m.spinner.visible = false
        m.spinnerAnim.control = "stop"
        m.loadingLabel.visible = false
        printPlaybackDiagnostics()
        if shouldRepairUnsupportedAac()
            channel = m.top.playlist[m.currentIndex]
            key = audioRepairKey(channel)
            if key <> "" then m.audioRepairKnown[key] = true
            print "[MEDIA] unsupported AAC detected; starting local repair"
            startAudioRepair(m.currentIndex)
            return
        end if
        m.lastPlaybackError = playbackErrorText()
        showErrorDialog()
    end if
    dashboardObserveState()
end sub

function shouldRepairUnsupportedAac() as boolean
    if m.audioRepairActive then return false
    if m.currentIndex < 0 or m.top.playlist = invalid then return false
    if m.currentIndex >= m.top.playlist.Count() then return false
    channel = m.top.playlist[m.currentIndex]
    if not channelSupportsAudioRepair(channel) then return false

    detail = mediaErrorDetail()
    return detail.Instr("unsupported aac stream") >= 0
end function

function mediaErrorDetail() as string
    detail = ""
    if m.video.errorStr <> invalid then detail = detail + " " + m.video.errorStr.ToStr()
    if m.video.errorMsg <> invalid then detail = detail + " " + m.video.errorMsg.ToStr()
    info = m.video.errorInfo
    if info <> invalid and GetInterface(info, "ifAssociativeArray") <> invalid
        if info.dbgmsg <> invalid then detail = detail + " " + info.dbgmsg.ToStr()
    end if
    return LCase(detail)
end function

function channelSupportsAudioRepair(channel as dynamic) as boolean
    if channel = invalid or channel.url = invalid then return false
    url = LCase(channel.url.ToStr())
    if not url.StartsWith("http://") and not url.StartsWith("https://") then return false
    ' The local relay rewrites HLS manifests. Do not feed a bare transport stream
    ' or another container to its manifest parser.
    return url.Instr(".m3u8") >= 0
end function

function audioRepairKey(channel as dynamic) as string
    if channel = invalid then return ""
    if channel.providerStreamId <> invalid and channel.providerStreamId.ToStr() <> ""
        return "stream:" + channel.providerStreamId.ToStr()
    end if
    if channel.url <> invalid and channel.url.ToStr() <> ""
        return "url:" + channel.url.ToStr()
    end if
    return ""
end function

sub startAudioRepair(idx as integer)
    if m.top.playlist = invalid or idx < 0 or idx >= m.top.playlist.Count() then return
    channel = m.top.playlist[idx]
    if not channelSupportsAudioRepair(channel) then return

    m.audioRepairPendingIndex = idx
    m.audioRepairActive = true
    m.video.control = "stop"
    m.errorDialog.visible = false
    m.spinner.visible = true
    m.spinnerAnim.control = "start"
    m.loadingLabel.text = "Repairing audio: " + channel.name
    m.loadingLabel.visible = true

    if m.audioRepairTask = invalid or m.audioRepairTask.status = "error"
        m.audioRepairTask = CreateObject("roSGNode", "LocalProxyTask")
        m.audioRepairTask.listenPort = m.audioRepairPort
        m.audioRepairTask.transformMode = "aac-main-to-lc"
        m.audioRepairTask.observeField("status", "onAudioRepairStatus")
        m.audioRepairTask.sourceUrl = channel.url
        m.audioRepairTask.control = "RUN"
    else
        m.audioRepairTask.sourceUrl = channel.url
        if m.audioRepairTask.status = "ready" then playPendingAudioRepair()
    end if
end sub

sub onAudioRepairStatus()
    if m.audioRepairTask = invalid then return
    if m.audioRepairTask.status = "ready"
        print "[MEDIA] local audio repair ready"
        playPendingAudioRepair()
    else if m.audioRepairTask.status = "error"
        print "[MEDIA] local audio repair could not start"
        m.audioRepairPendingIndex = -1
        m.spinner.visible = false
        m.spinnerAnim.control = "stop"
        m.loadingLabel.visible = false
        m.lastPlaybackError = "Roku could not start the on-device audio repair."
        publishPlayerTelemetry("error")
        showErrorDialog()
    end if
end sub

sub playPendingAudioRepair()
    idx = m.audioRepairPendingIndex
    if idx < 0 or idx <> m.currentIndex then return
    if m.top.playlist = invalid or idx >= m.top.playlist.Count() then return
    channel = m.top.playlist[idx]
    m.audioRepairTask.sourceUrl = channel.url
    m.audioRepairSession = m.audioRepairSession + 1
    localUrl = "http://127.0.0.1:" + m.audioRepairPort.ToStr().Trim() + "/proxy.m3u8?session=" + m.audioRepairSession.ToStr().Trim()
    m.audioRepairPendingIndex = -1
    print "[MEDIA] retrying through local audio repair"
    playChannelUrl(channel, localUrl, true)
end sub

sub onAvailableAudioTracks()
    tracks = m.video.availableAudioTracks
    count = 0
    if tracks <> invalid then count = tracks.Count()
    print "[MEDIA] availableAudioTracks="; count
    if tracks = invalid then return
    for each track in tracks
        codec = mediaField(track, "Codec")
        language = mediaField(track, "Language")
        print "[MEDIA] audioTrack codec="; codec; " language="; language
    end for
end sub

function mediaField(value as dynamic, key as string) as string
    if value = invalid or GetInterface(value, "ifAssociativeArray") = invalid then return ""
    field = value[key]
    if field = invalid then return ""
    return field.ToStr()
end function

function safeMediaDiagnostic(value as dynamic) as string
    if value = invalid then return ""
    text = value.ToStr()
    lower = LCase(text)
    if lower.Instr("http://") >= 0 or lower.Instr("https://") >= 0 then return "[URL redacted]"
    if text.Len() > 240 then text = text.Left(240)
    return text
end function

sub printPlaybackDiagnostics()
    print "[MEDIA] state=error code="; m.video.errorCode; " message="; safeMediaDiagnostic(m.video.errorMsg)
    print "[MEDIA] audioFormat="; m.video.audioFormat; " videoFormat="; m.video.videoFormat
    print "[MEDIA] errorStr="; safeMediaDiagnostic(m.video.errorStr)
    info = m.video.errorInfo
    if info <> invalid and GetInterface(info, "ifAssociativeArray") <> invalid
        print "[MEDIA] error category="; mediaField(info, "category"); " errcode="; mediaField(info, "errcode"); " source="; mediaField(info, "source")
        print "[MEDIA] dbgmsg="; safeMediaDiagnostic(info.dbgmsg)
    end if
    onAvailableAudioTracks()
end sub

function playbackErrorText() as string
    codeText = ""
    if m.video.errorCode <> invalid then codeText = m.video.errorCode.ToStr()

    message = ""
    if m.video.errorMsg <> invalid then message = m.video.errorMsg.Trim()
    ' Do not allow a player diagnostic to put a credential-bearing media URL on
    ' screen. The numeric Roku error remains available even when detail is hidden.
    if message.Instr("http://") >= 0 or message.Instr("https://") >= 0
        message = ""
    else if message.Len() > 160
        message = message.Left(160)
    end if

    if codeText <> "" and message <> "" and LCase(message) <> "ignored"
        return "Roku error " + codeText + ": " + message
    else if codeText <> ""
        return "Roku playback error " + codeText + "."
    else if message <> "" and LCase(message) <> "ignored"
        return message
    end if
    return "Roku could not decode or retrieve this stream."
end function

' Labels and actions are written in ONE pass into two parallel lists, so the menu's length
' and its behaviour cannot drift apart. This menu is now variable-length, and the dispatch
' below reads m.errorActions rather than a fixed index -- with hardcoded indices, dropping
' one row would silently move "Back" from 3 to 2, so Back would do nothing and index 2
' would toggle favourites on a channel that has none.
function buildErrorOptions() as object
    c = CreateObject("roSGNode", "ContentNode")
    m.errorActions = []

    addErrorOption(c, "Retry")
    m.errorActions.Push("retry")

    addErrorOption(c, "Next channel")
    m.errorActions.Push("next")

    ' Offered ONLY when the channel already is a favourite. This dialog is open because the
    ' stream would not play, so inviting the user to bookmark it made no sense. The REMOVE
    ' case is the reason the option exists at all (TASK-18 Part B): a dead favourite cannot
    ' be removed from the grid, because this dialog holds the focus.
    isFav = false
    if m.currentIndex >= 0 and m.top.playlist <> invalid
        ch = m.top.playlist[m.currentIndex]
        if ch <> invalid then isFav = IsFavorite(ch.name)
    end if
    if isFav
        addErrorOption(c, "Remove from favorites")
        m.errorActions.Push("fav")
    end if

    addErrorOption(c, "Back")
    m.errorActions.Push("back")

    return c
end function

sub showErrorDialog()
    if m.lastPlaybackError <> invalid and m.lastPlaybackError <> ""
        m.errorMsg.text = m.lastPlaybackError
    else
        m.errorMsg.text = "Couldn't play this stream."
    end if
    m.errorOptions.content = buildErrorOptions()
    m.errorDialog.visible = true
    m.errorOptions.setFocus(true)
end sub

sub onErrorOptionSelected()
    idx = m.errorOptions.itemSelected
    ' Bound-check rather than trust. itemSelected is a plain integer and can outlive the
    ' menu it indexed: the favourite row removes itself, so the content is rebuilt one row
    ' shorter while the cursor still holds the old position.
    if m.errorActions = invalid or idx < 0 or idx >= m.errorActions.Count() then return
    action = m.errorActions[idx]

    if action = "retry"
        if m.currentIndex >= 0 then playIndex(m.currentIndex)
    else if action = "next"
        zapDown()
    else if action = "fav"
        if m.currentIndex >= 0 and m.top.playlist <> invalid
            ch = m.top.playlist[m.currentIndex]
            if ch <> invalid
                ' The row is only built for a channel that IS a favourite, and nothing can
                ' change that while this dialog holds focus -- onKeyEvent's errorDialog
                ' branch passes only back/OK/up/down, so the "*" toggle cannot reach the
                ' player here. So this is always a removal today. The toast still reports
                ' what ToggleFavorite actually DID rather than what that reasoning predicts,
                ' because the reasoning is about the current key handling and the toast
                ' should not start lying if that changes.
                isFav = ToggleFavorite(ch.name)
                if isFav
                    showToast("Added to favorites")
                else
                    showToast("Removed from favorites")
                end if
                ' Rebuild, because the row just removed itself. Replacing `content` resets
                ' the list to its first item on its own, so no jumpToItem is needed --
                ' and note this LabelList PINS the focused row at the top of the panel and
                ' scrolls the items under it, so "which row is highlighted" cannot be read
                ' from a screenshot by y-coordinate. Press an arrow and compare two
                ' captures instead.
                m.errorOptions.content = buildErrorOptions()
                m.errorOptions.setFocus(true)
            end if
        end if
    else if action = "back"
        exitPlayer()
    end if
end sub

sub showOverlay()
    ' The two panels overlap. Without this the banner draws on top of the overlay
    ' whenever OK is pressed within the banner's few seconds.
    hideMiniBanner()
    m.overlayGroup.visible = true
    updateClock()
    m.clockTimer.control = "start"
    m.overlayTimer.control = "start"
end sub

sub hideOverlay()
    m.overlayGroup.visible = false
    m.clockTimer.control = "stop"
end sub

sub updateOverlayData(channel as object)
    m.overlayName.text = channel.name
    if channel.group <> invalid
        m.overlayGroupLabel.text = channel.group
    else
        m.overlayGroupLabel.text = ""
    end if
    
    info = EpgFind(m.global.epg, channel.name, m.global.nowSec)
    s = ""
    if info.now <> invalid then s = "Now: " + info.now.t + " (" + EpgFmtHM(info.now.s) + "-" + EpgFmtHM(info.now.e) + ")"
    if info.next <> invalid then s = s + "   Next: " + info.next.t
    m.overlayEpg.text = s
end sub

' Row 1 is always the channel. Row 2 is the programme when the guide has one, and
' the channel's category when it does not -- roughly two thirds of channels have no
' guide at all, and the whole Sport2 category has none, so a "no programme
' information" string would be the most-shown text in the app and would repeat for
' hundreds of consecutive zaps. The category is always true, always non-empty
' (M3uParser falls back to "Uncategorized") and tells the viewer where they are.
' Which of the two it is reads from the colour, from the presence of the end time,
' and from the progress foot -- three signals, no layout change either way.
sub showMiniBanner(channel as object)
    if channel = invalid then return

    m.miniBannerLabel.text = channel.name

    info = EpgFind(m.global.epg, channel.name, m.global.nowSec)
    dur = 3.0
    if info.now <> invalid
        m.zapLine2.text = info.now.t
        m.zapLine2.color = m.theme.colorText
        m.zapUntil.text = "until " + EpgFmtHM(info.now.e)
        setZapProgress(info.now)
        dur = 4.5          ' more to read; every zap restarts the timer, so a burst
                           ' only ever runs the LAST banner to completion
    else
        grp = ""
        if channel.group <> invalid then grp = channel.group
        m.zapLine2.text = grp
        m.zapLine2.color = m.theme.colorTextDim
        m.zapUntil.text = ""
        m.zapProgress.visible = false
    end if

    m.miniBanner.visible = true
    ' Assigning duration to a RUNNING timer is unreliable: stop, set, start.
    m.miniBannerTimer.control = "stop"
    m.miniBannerTimer.duration = dur
    m.miniBannerTimer.control = "start"
end sub

' Computed once, at show time. The banner lives 3-4.5s, over which the bar would
' move about 0.05% of its width -- observing nowSec to animate it would be pure cost
' on the zap hot path.
sub setZapProgress(prog as object)
    span = prog.e - prog.s
    if span <= 0
        m.zapProgress.visible = false
        return
    end if
    nowSec = m.global.nowSec
    if nowSec = invalid or nowSec <= 0 then nowSec = CreateObject("roDateTime").AsSeconds()
    frac = (nowSec - prog.s) / span
    if frac < 0 then frac = 0
    if frac > 1 then frac = 1
    w = Int(1040 * frac)
    if w < 8 then w = 8   ' a just-started programme must not read as "no data"
    m.zapProgress.width = w
    m.zapProgress.visible = true
end sub

sub hideMiniBanner()
    m.miniBannerTimer.control = "stop"
    m.miniBanner.visible = false
end sub

sub showToast(msg as string)
    m.toastLabel.text = msg
    m.toastBg.visible = true
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toastBg.visible = false
end sub

sub onOkLongPress()
    m.okLongFired = true
    if m.currentIndex < 0 or m.top.playlist = invalid then return
    ch = m.top.playlist[m.currentIndex]
    if ch = invalid then return
    isFav = ToggleFavorite(ch.name)
    if isFav
        showToast("Added to favorites")
    else
        showToast("Removed from favorites")
    end if
end sub

sub updateClock()
    dt = CreateObject("roDateTime")
    dt.ToLocalTime()
    h = dt.GetHours().ToStr()
    m_str = dt.GetMinutes().ToStr()
    if h.Len() = 1 then h = "0" + h
    if m_str.Len() = 1 then m_str = "0" + m_str
    m.overlayTime.text = h + ":" + m_str
end sub

sub zapUp()
    zap(-1)
end sub

sub zapDown()
    zap(1)
end sub

sub zap(stepDelta as integer)
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 return
    
    count = m.top.playlist.Count()
    idx = m.currentIndex
    
    for i = 1 to count
        idx = idx + stepDelta
        if idx < 0
            idx = count - 1
        else if idx >= count
            idx = 0
        end if
        
        ch = m.top.playlist[idx]
        if ch <> invalid and ch.compatible = true
            playIndex(idx)
            return
        end if
    end for
end sub

sub exitPlayer()
    m.video.control = "stop"
    m.errorDialog.visible = false
    m.top.exitRequested = not m.top.exitRequested
end sub

sub openZapper()
    if m.top.playlist = invalid or m.top.playlist.Count() = 0 then return
    ' Time the rebuild. This runs on the render thread, so it must be the GLOBAL Uptime()
    ' and never CreateObject("roTimespan") -- that is a MAIN|TASK-only component and rule
    ' 20 makes it a hard failure here. The number settles a standing open item: the panel
    ' recreates every node on every open, and nobody has ever measured whether that costs
    ' anything on 1548 channels or is lost in the noise.
    t0 = Uptime(0)
    ' hide overlay/banner
    hideOverlay()
    hideMiniBanner()
    ' build content from the current category
    root = CreateObject("roSGNode", "ContentNode")
    
    favSet = {}
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            favSet[f] = true
        end for
    end if
    
    for each ch in m.top.playlist
        item = root.createChild("ChannelContent")
        item.name = ch.name
        item.favorite = (favSet[ch.name] <> invalid)
        item.compatible = (ch.compatible = true)
    end for
    m.zapperGrid.content = root
    if m.currentIndex >= 0 then m.zapperGrid.jumpToItem = m.currentIndex
    m.zapperPanel.visible = true
    m.zapperGrid.setFocus(true)         ' focus the GRID, not the panel (rule #9)
    m.zapperTimer.control = "start"
    ' Index, never the group title: the console on 8085 is unauthenticated, and one of
    ' this playlist's categories is one the owner would not want printed.
    print "[ZAPPER] open items="; m.top.playlist.Count(); " ms="; Int((Uptime(0) - t0) * 1000)
end sub

sub focusPlayer()
    if m.errorOptions <> invalid then m.errorOptions.setFocus(false)
    if m.zapperGrid <> invalid then m.zapperGrid.setFocus(false)
    m.top.setFocus(true)
end sub

sub closeZapper()
    m.zapperTimer.control = "stop"
    m.zapperPanel.visible = false
    focusPlayer()
end sub

sub onZapperFocused()
    ' activity — restart auto-hide
    if m.zapperPanel.visible
        m.zapperTimer.control = "stop"
        m.zapperTimer.control = "start"
    end if
end sub

sub onZapperSelected()
    if not m.zapperPanel.visible then return   ' panel hidden — ignore
    idx = m.zapperGrid.itemSelected
    if idx = invalid or m.top.playlist = invalid then return
    if idx < 0 or idx >= m.top.playlist.Count() then return
    ch = m.top.playlist[idx]
    if ch = invalid then return
    if ch.compatible <> true
        showToast("Stream not supported")
        return                          ' keep the panel open, don't change channel
    end if
    closeZapper()
    playIndex(idx)                      ' playIndex focuses the player and updates everything
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false
    if m.zapperPanel.visible
        if press
            m.zapperTimer.control = "stop"
            m.zapperTimer.control = "start"
            if key = "back"
                closeZapper()
                handled = true
            else if key = "up" or key = "down" or key = "OK"
                handled = false                 ' navigation and select go to the grid
            else if key = "left" or key = "right" or key = "options"
                handled = true                  ' swallow
            end if
        else
            if key = "back" or key = "left" or key = "right" or key = "options"
                handled = true
            end if
        end if
    else if m.errorDialog.visible
        if press
            if key = "back"
                exitPlayer()
                handled = true
            else if key = "OK" or key = "up" or key = "down"
                ' Let errorOptions handle it
                handled = false
            end if
        end if
    else
        if key = "OK"
            if press
                m.okLongFired = false
                m.okTimer.control = "start"
                handled = true
            else
                m.okTimer.control = "stop"
                if m.okLongFired = false
                    if m.overlayGroup.visible
                        hideOverlay()
                    else
                        showOverlay()
                    end if
                end if
                handled = true
            end if
        else if press
            if key = "back"
                exitPlayer()
                handled = true
            else if key = "up"
                zapUp()
                handled = true
            else if key = "down"
                zapDown()
                handled = true
            else if key = "left"
                openZapper()
                handled = true
            else if key = "options"
                if m.currentIndex >= 0 and m.top.playlist <> invalid
                    ch = m.top.playlist[m.currentIndex]
                    isFav = ToggleFavorite(ch.name)
                    if isFav
                        showToast("Added to favorites")
                    else
                        showToast("Removed from favorites")
                    end if
                end if
                handled = true
            end if
        end if
    end if
    return handled
end function
