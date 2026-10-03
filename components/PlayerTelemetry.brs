sub initDashboardTelemetry()
    m.dashboardRevision = 0
    m.dashboardSessionBytes = 0.0
    m.dashboardTuneBytes = 0.0
    m.dashboardBytesKnown = false
    m.dashboardMetric = dashboardEmptyMetrics()
    m.dashboardTuneStarted = Uptime(0)
    m.dashboardRateStarted = Uptime(0)
    m.dashboardRateBytes = 0.0
    m.dashboardBufferStart = -1
    m.dashboardBufferMs = 0
    m.dashboardBufferCount = 0
    m.dashboardCommand = ""
    m.dashboardLastSegment = ""
    m.video.observeField("downloadedSegment", "onDashboardSegment")
    m.top.findNode("telemetryTimer").observeField("fire", "onDashboardTelemetryTick")
    m.top.findNode("telemetryTimer").control = "start"
end sub

sub dashboardBeginTune(channel as object)
    m.dashboardRevision = m.dashboardRevision + 1
    m.dashboardCommand = m.top.dashboardCommandId
    m.top.dashboardCommandId = ""
    m.dashboardTuneBytes = 0.0
    m.dashboardMetric = dashboardEmptyMetrics()
    m.dashboardTuneStarted = Uptime(0)
    m.dashboardRateStarted = Uptime(0)
    m.dashboardRateBytes = 0.0
    m.dashboardBufferStart = -1
    m.dashboardBufferMs = 0
    m.dashboardBufferCount = 0
    m.dashboardLastSegment = ""
    m.dashboardCurrent = dashboardChannel(channel)
    publishPlayerTelemetry("tuning")
end sub

sub dashboardObserveState()
    state = m.video.state
    elapsed = (Uptime(0) - m.dashboardTuneStarted) * 1000.0
    if state = "buffering" and m.dashboardBufferStart < 0
        m.dashboardBufferStart = elapsed
        m.dashboardBufferCount = m.dashboardBufferCount + 1
    else if state <> "buffering" and m.dashboardBufferStart >= 0
        m.dashboardBufferMs = m.dashboardBufferMs + elapsed - m.dashboardBufferStart
        m.dashboardBufferStart = -1
    end if
    if state = "playing" and m.dashboardMetric.startupMs = invalid then m.dashboardMetric.startupMs = elapsed
    publishPlayerTelemetry(state)
end sub

sub onDashboardSegment(event as object)
    segment = event.GetData()
    if segment = invalid then return
    if segment.Status <> 0 or segment.SegSize = invalid then return
    key = dashboardText(segment.Path) + "|" + dashboardText(segment.SegSequence) + "|" + dashboardText(segment.SegType)
    if key = m.dashboardLastSegment then return
    m.dashboardLastSegment = key
    m.dashboardBytesKnown = true
    m.dashboardSessionBytes = m.dashboardSessionBytes + segment.SegSize
    m.dashboardTuneBytes = m.dashboardTuneBytes + segment.SegSize
    m.dashboardRateBytes = m.dashboardRateBytes + segment.SegSize
    if segment.BitrateBPS <> invalid then m.dashboardMetric.bitrate = segment.BitrateBPS
    if segment.Width <> invalid and segment.Width > 0 then m.dashboardMetric.width = segment.Width
    if segment.Height <> invalid and segment.Height > 0 then m.dashboardMetric.height = segment.Height
end sub

sub onDashboardTelemetryTick()
    elapsed = (Uptime(0) - m.dashboardRateStarted) * 1000.0
    if elapsed >= 1000 and m.dashboardBytesKnown
        m.dashboardMetric.bytesPerSecond = m.dashboardRateBytes * 1000.0 / elapsed
        m.dashboardRateBytes = 0.0
        m.dashboardRateStarted = Uptime(0)
    end if
    publishPlayerTelemetry(m.video.state)
end sub

sub publishPlayerTelemetry(state as string)
    if state = "finished" then state = "stopped"
    if state <> "idle" and state <> "tuning" and state <> "playing" and state <> "buffering" and state <> "paused" and state <> "error" and state <> "stopped" then state = "idle"
    if m.dashboardBytesKnown
        m.dashboardMetric.sessionBytes = m.dashboardSessionBytes
        m.dashboardMetric.tuneBytes = m.dashboardTuneBytes
    end if
    m.dashboardMetric.bufferingCount = m.dashboardBufferCount
    m.dashboardMetric.bufferingMs = m.dashboardBufferMs
    if m.dashboardBufferStart >= 0 then m.dashboardMetric.bufferingMs = m.dashboardBufferMs + (Uptime(0) - m.dashboardTuneStarted) * 1000.0 - m.dashboardBufferStart
    m.top.dashboardSnapshot = { state: state, playbackRevision: m.dashboardRevision, channel: m.dashboardCurrent, commandId: m.dashboardCommand, metrics: m.dashboardMetric }
end sub
