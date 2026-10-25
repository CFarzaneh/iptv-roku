sub main()
    m.checks = 0
    resetPlayer()
    event = {GetData: function() as object
        width = CreateObject("roInt"): width.SetInt(1920)
        height = CreateObject("roInt"): height.SetInt(1080)
        return {revision: 9, width: width, height: height}
    end function}
    onResolutionInspected(event)
    check(m.dashboardMetric.width = 1920 and m.dashboardMetric.height = 1080 and m.published = 1, "measured dimensions reach telemetry")
    check(Type(m.dashboardMetric.width) = "Integer", "task boxes normalized before JSON")

    resetPlayer()
    stale = {GetData: function() as object
        return {revision: 8, width: 3840, height: 2160}
    end function}
    onResolutionInspected(stale)
    check(m.dashboardMetric.width = invalid and m.resolutionTask.revision = 9 and m.published = 0, "stale result cannot modify new channel or clear its task")

    resetPlayer()
    m.dashboardMetric.width = 1280: m.dashboardMetric.height = 720
    onResolutionInspected(event)
    check(m.dashboardMetric.width = 1280 and m.published = 0, "existing native metadata takes priority")

    resetPlayer()
    m.recovery.active = false
    onResolutionInspected(event)
    check(m.dashboardMetric.width = invalid and m.published = 0, "exit discards late completion")

    resetPlayer()
    unavailable = {GetData: function() as object
        return {revision: 9}
    end function}
    onResolutionInspected(unavailable)
    check(m.recovery.active and m.resolutionTask = invalid and m.dashboardMetric.width = invalid, "unavailable sample leaves playback active and frees task")

    resetPlayer()
    task = m.resolutionTask
    resetResolutionFallback()
    check(task.cancel and m.resolutionTask = invalid and m.resolutionAttempts = 0, "tune cancellation and budget reset")
    maybeInspectResolution({segType: 0, segUrl: "http://example.com/live/u/p/1.ts"})
    check(m.resolutionAttempts = 0, "direct live entry never probed")
    maybeInspectResolution({segType: 0, segUrl: m.video.content.url})
    check(m.resolutionAttempts = 0, "current channel never reopened")

    resetPlayer()
    m.audioRepairActive = true
    m.currentIndex = 0
    m.top = {playlist: [{url: "http://example.com/channel.m3u8"}]}
    applyAudioRepairDimensions({sourceUrl: "http://example.com/old.m3u8", width: 3840, height: 2160})
    check(m.dashboardMetric.width = invalid, "AAC old channel ignored")
    applyAudioRepairDimensions({sourceUrl: m.top.playlist[0].url, width: 1920, height: 1080})
    check(m.dashboardMetric.width = 1920 and m.published = 1, "AAC data reused without another download")
    print "Player resolution checks passed: "; m.checks
end sub

sub resetPlayer()
    m.recovery = {active: true}
    m.dashboardMetric = dashboardEmptyMetrics()
    m.dashboardRevision = 9
    m.dashboardPlayingSegmentKnown = false
    m.resolutionTask = {revision: 9, cancel: false}
    m.resolutionAttempts = 1
    m.video = {state: "playing", content: {url: "http://example.com/channel.m3u8"}}
    m.published = 0
end sub

sub publishPlayerTelemetry(_state as string)
    m.published = m.published + 1
end sub

sub check(condition as boolean, label as string)
    m.checks = m.checks + 1
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
