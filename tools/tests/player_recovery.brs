' Controller tests use a simulated Video node and clock; no TV or provider is contacted.
sub main()
    m.checks = 0
    resetPlayer()
    check(recoverPlaybackError(), "server error queues recovery")
    check(m.loadingLabel.text = "Reconnecting…" and not m.errorDialog.visible, "reconnecting UI")
    m.now = 0.5
    onPlaybackRecoveryTick()
    check(m.playCalls = 0, "timer cannot restart early")
    m.now = 1
    onPlaybackRecoveryTick()
    check(m.playCalls = 1 and m.lastPlayedIndex = 4 and m.lastPlayedAutomatic, "same channel restarted once")
    check(m.video.control = "stop" and m.recovery.attempts = 1, "old connection released and budget preserved")
    m.now = 2
    onPlaybackRecoveryTick()
    check(m.playCalls = 1, "no duplicate restart")
    check(recoverPlaybackError(), "next transient error queued")
    old = m.recovery
    beginPlaybackRecovery(false)
    m.currentIndex = 9
    m.video.state = "buffering"
    m.now = 6
    onPlaybackRecoveryTick()
    check(not old.active and m.recovery.attempts = 0 and m.playCalls = 1, "channel selection cancels old retry")

    resetPlayer()
    check(recoverPlaybackError(), "exit test queued")
    cancelPlaybackRecovery()
    m.now = 50
    onPlaybackRecoveryTick()
    check(m.playCalls = 0 and not m.recovery.pending and m.recoveryTimer.control = "stop", "exit cancels queued timer")
    check(m.audioRepairPendingIndex = -1, "exit cancels delayed AAC playback")

    resetPlayer()
    m.errorDetail = "response code:(403):403"
    check(not recoverPlaybackError() and not m.recovery.pending, "access denial never queued")

    resetPlayer()
    m.zapperPanel.visible = true
    check(recoverPlaybackError() and m.focusCalls = 0, "recovery leaves channel selector usable")

    resetPlayer()
    m.recovery.attempts = 3
    m.video.state = "buffering"
    recoveryObserve(m.recovery, "buffering", 0, 0)
    m.now = 30
    onPlaybackRecoveryTick()
    check(m.dialogCalls = 1 and m.reportState = "error", "exhaustion shows existing menu and reports failure")
    check(not m.recovery.active and m.video.control = "stop" and not m.spinner.visible, "failed recovery is stopped")
    m.now = 100
    onPlaybackRecoveryTick()
    check(m.dialogCalls = 1 and m.playCalls = 0, "exhausted watchdog cannot keep retrying")

    resetPlayer()
    m.video.state = "buffering"
    recoveryObserve(m.recovery, "buffering", 0, 0)
    m.now = 30
    onPlaybackRecoveryTick()
    check(m.recovery.pending and m.reportState = "buffering", "buffering watchdog reports recovery")
    m.video.state = "playing"
    m.video.position = 1
    m.now = 30.5
    onPlaybackRecoveryTick()
    check(not m.recovery.pending and m.playCalls = 0, "natural recovery prevents unnecessary reconnect")

    resetPlayer()
    m.video.state = "finished"
    onPlaybackRecoveryTick()
    check(m.recovery.pending, "unexpected live end recovers even before first frame")
    print "Player recovery controller checks passed: "; m.checks
end sub

sub resetPlayer()
    m.now = 0
    m.recovery = newPlaybackRecovery(0)
    m.recoveryTimer = {control: "start"}
    m.video = {state: "error", position: 0, control: "play", errorCode: -1, errorInfo: {category: "http"}}
    m.currentIndex = 4
    m.audioRepairPendingIndex = 4
    m.spinner = {visible: false}
    m.spinnerAnim = {control: "stop"}
    m.errorDialog = {visible: false}
    m.zapperPanel = {visible: false}
    m.loadingLabel = {text: "", visible: false}
    m.errorDetail = "HTTP response code said error response code:(500):500"
    m.playCalls = 0
    m.dialogCalls = 0
    m.focusCalls = 0
    m.reportState = ""
end sub

function Uptime(_unused as integer) as double
    return m.now * 1#
end function

sub playIndex(idx as integer, automaticRetry as boolean)
    m.playCalls = m.playCalls + 1
    m.lastPlayedIndex = idx
    m.lastPlayedAutomatic = automaticRetry
    beginPlaybackRecovery(automaticRetry)
    m.video.state = "buffering"
end sub

sub focusPlayer()
    m.focusCalls = m.focusCalls + 1
end sub

sub closeZapper()
    m.zapperPanel.visible = false
end sub

function mediaField(info as object, key as string) as string
    return info[key]
end function

function mediaErrorDetail() as string
    return m.errorDetail
end function

sub dashboardObserveState(state as string)
    m.reportState = state
end sub

sub publishPlayerTelemetry(state as string)
    m.reportState = state
end sub

sub showErrorDialog()
    m.dialogCalls = m.dialogCalls + 1
end sub

sub check(condition as boolean, label as string)
    m.checks = m.checks + 1
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
