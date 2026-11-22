sub main()
    m.video = {state: "finished", position: 1200, control: "play"}
    m.recovery = newPlaybackRecovery(0)
    m.recoveryTimer = {control: "start"}
    m.overlayGroup = {visible: true}
    m.clockTimer = {control: "start"}
    m.errorDialog = {visible: false}
    m.top = {exitRequested: false}
    m.isVod = true
    m.vodKey = ""
    m.vodHasPosition = true
    onVideoStateChange()
    if not m.top.exitRequested or m.recovery.active or m.recovery.pending or m.video.control <> "stop" or m.vodHasPosition
        print "FAILED: completed movie must leave the player without retrying"
        stop
    end if
    print "Movie completion check passed"
end sub

function Uptime(_unused as integer) as double
    return 1200#
end function
