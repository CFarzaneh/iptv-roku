sub initOnDemandPlayback()
    m.vodProgress = m.top.findNode("vodProgress")
    m.vodProgressFill = m.top.findNode("vodProgressFill")
    m.video.observeField("position", "onOnDemandPosition")
    m.vodKey = ""
    m.isVod = false
end sub

sub beginOnDemandPlayback(item as object, automaticRetry as boolean)
    m.isVod = isOnDemand(item)
    if m.isVod
        if not automaticRetry or m.vodKey <> item.resumeKey
            m.vodKey = item.resumeKey
            m.vodPosition = readOnDemandPosition(m.vodKey)
            m.vodSavedPosition = m.vodPosition
            m.vodLastCheckpoint = Uptime(0)
        end if
    else
        m.vodKey = ""
        m.vodPosition = 0
    end if
    m.vodHasPosition = false
    m.vodProgress.visible = false
end sub

sub onOnDemandPosition()
    if not m.isVod or not m.recovery.active or m.recovery.pending then return
    state = m.video.state
    if state <> "playing" and state <> "paused" then return
    seconds = dashboardNumericValue(m.video.position)
    if seconds = invalid then return
    if seconds < 0 then return
    m.vodPosition = seconds
    m.vodHasPosition = true
    if m.overlayGroup.visible then updateOnDemandProgress()
    if Uptime(0) - m.vodLastCheckpoint >= 20 then saveOnDemandCheckpoint()
end sub

sub saveOnDemandCheckpoint()
    if not m.isVod or not m.vodHasPosition then return
    m.vodLastCheckpoint = Uptime(0)
    position = Fix(m.vodPosition)
    if position < 10 then position = 0
    if position = m.vodSavedPosition then return
    if writeOnDemandPosition(m.vodKey, position) then m.vodSavedPosition = position
end sub

sub updateOnDemandProgress()
    duration = dashboardNumericValue(m.video.duration)
    if duration = invalid then duration = 0
    elapsed = onDemandTime(m.vodPosition)
    if duration > 0 then elapsed = elapsed + " / " + onDemandTime(duration)
    if m.video.state = "paused" then elapsed = "Paused   ·   " + elapsed
    m.overlayTime.text = elapsed
    m.overlayEpg.text = "◀ / ▶  Skip 30 seconds"
    m.vodProgress.visible = duration > 0
    if duration > 0
        ratio = m.vodPosition / duration
        if ratio > 1 then ratio = 1
        m.vodProgressFill.width = 1720 * ratio
    end if
end sub

function onDemandTime(seconds as double) as string
    value = Fix(seconds)
    hours = value \ 3600
    minutes = (value \ 60) mod 60
    secs = Str(value mod 60).Trim()
    if secs.Len() = 1 then secs = "0" + secs
    mins = Str(minutes).Trim()
    if hours = 0 then return mins + ":" + secs
    if mins.Len() = 1 then mins = "0" + mins
    return Str(hours).Trim() + ":" + mins + ":" + secs
end function

function handleOnDemandKey(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back"
        exitPlayer()
        return true
    end if
    state = m.video.state
    if key = "OK"
        if m.overlayGroup.visible then hideOverlay() else showOverlay()
        return true
    end if
    if state <> "playing" and state <> "paused" then return false
    if key = "play" or key = "playonly" or key = "pause"
        if state = "playing" and key <> "playonly" then m.video.control = "pause"
        if state = "paused" and key <> "pause" then m.video.control = "resume"
        showOverlay()
        return true
    end if

    offset = 0
    if key = "left" or key = "rewind" then offset = -30
    if key = "right" or key = "fastforward" then offset = 30
    if key = "replay" then offset = -15
    if offset = 0 then return false
    target = m.vodPosition + offset
    duration = dashboardNumericValue(m.video.duration)
    if duration <> invalid
        if duration > 1 and target >= duration then target = duration - 1
    end if
    if target < 0 then target = 0
    m.video.autoplayAfterSeek = state = "playing"
    m.video.seek = target
    showOverlay()
    return true
end function
