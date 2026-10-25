sub initPlaybackRecovery()
    m.recovery = newPlaybackRecovery(Uptime(0))
    recoveryCancel(m.recovery)
    m.recoveryTimer = m.top.findNode("recoveryTimer")
    m.recoveryTimer.observeField("fire", "onPlaybackRecoveryTick")
end sub

sub beginPlaybackRecovery(automaticRetry as boolean)
    if not automaticRetry
        recoveryCancel(m.recovery)
        m.recovery = newPlaybackRecovery(Uptime(0))
    end if
    recoveryBeginAttempt(m.recovery, Uptime(0))
    m.recoveryTimer.control = "start"
end sub

sub cancelPlaybackRecovery()
    recoveryCancel(m.recovery)
    m.recoveryTimer.control = "stop"
    m.audioRepairPendingIndex = -1
end sub

function queuePlaybackRecovery(limit as integer, reason as string) as boolean
    if not recoveryRequest(m.recovery, limit, reason, Uptime(0)) then return false
    m.errorDialog.visible = false
    m.spinner.visible = true
    m.spinnerAnim.control = "start"
    m.loadingLabel.text = "Reconnecting…"
    m.loadingLabel.visible = true
    if m.zapperPanel = invalid or not m.zapperPanel.visible then focusPlayer()
    return true
end function

function recoverPlaybackError() as boolean
    category = ""
    info = m.video.errorInfo
    if GetInterface(info, "ifAssociativeArray") <> invalid then category = mediaField(info, "category")
    code = m.video.errorCode
    if code = invalid then code = -3
    limit = recoveryErrorLimit(code, category, mediaErrorDetail(), m.recovery.everPlayed)
    return queuePlaybackRecovery(limit, "error")
end function

sub onPlaybackRecoveryTick()
    if not m.recovery.active then return
    now = Uptime(0)
    state = m.video.state
    recoveryObserve(m.recovery, state, m.video.position, now, recoveryPlaybackMarker())
    if recoveryTakeRetry(m.recovery, now)
        ' Stop before reopening to release the previous provider connection.
        m.video.control = "stop"
        print "[MEDIA] automatic retry attempt="; m.recovery.attempts
        playIndex(m.currentIndex, true)
        return
    end if
    reason = recoveryStallReason(m.recovery, state, now)
    if reason = "" then return
    m.lastPlaybackError = "The live stream ended unexpectedly."
    if reason <> "live-end" then m.lastPlaybackError = "The stream stopped making progress."
    if queuePlaybackRecovery(3, reason)
        dashboardObserveState("buffering")
    else
        failPlaybackRecovery()
    end if
end sub

sub failPlaybackRecovery()
    cancelPlaybackRecovery()
    m.video.control = "stop"
    m.spinner.visible = false
    m.spinnerAnim.control = "stop"
    m.loadingLabel.visible = false
    publishPlayerTelemetry("error")
    if m.zapperPanel <> invalid and m.zapperPanel.visible then closeZapper()
    showErrorDialog()
end sub

function recoveryPlaybackMarker() as string
    segment = m.video.streamingSegment
    if GetInterface(segment, "ifAssociativeArray") = invalid then return ""
    if segment.segType <> 0 and segment.segType <> 2 then return ""
    if segment.segSequence = invalid then return ""
    marker = segment.segSequence.ToStr()
    if segment.segStart <> invalid then marker = marker + "|" + segment.segStart.ToStr()
    return marker
end function
