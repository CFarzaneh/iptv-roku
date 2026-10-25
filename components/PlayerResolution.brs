sub resetResolutionFallback()
    cancelResolutionFallback()
    m.resolutionAttempts = 0
    m.resolutionLastUrl = ""
end sub

sub cancelResolutionFallback()
    if m.resolutionTask <> invalid then m.resolutionTask.cancel = true
    m.resolutionTask = invalid
end sub

sub maybeInspectResolution(segment as dynamic)
    if m.recovery = invalid then return
    if m.video.state <> "playing" or not m.recovery.active then return
    ' The AAC repair Task already inspects bytes it downloads for playback.
    if m.audioRepairActive = true then return
    if m.dashboardMetric.width <> invalid or m.resolutionTask <> invalid then return
    if m.resolutionAttempts >= 2 then return
    if GetInterface(segment, "ifAssociativeArray") = invalid then return
    kind = dashboardNumericValue(segment.segType)
    if kind <> 0 and kind <> 2 then return
    url = dashboardText(segment.segUrl)
    if m.video.content = invalid then return
    sourceUrl = m.video.content.url
    if url = m.resolutionLastUrl or not resolutionSafeSegment(url, sourceUrl) then return
    m.resolutionAttempts = m.resolutionAttempts + 1
    m.resolutionLastUrl = url
    task = CreateObject("roSGNode", "ResolutionTask")
    task.segmentUrl = url
    task.sourceUrl = sourceUrl
    task.revision = m.dashboardRevision
    task.attempt = m.resolutionAttempts
    task.codecHint = m.video.videoFormat
    task.observeField("result", "onResolutionInspected")
    m.resolutionTask = task
    task.control = "RUN"
end sub

sub onResolutionInspected(event as object)
    result = event.GetData()
    if result = invalid or result.revision <> m.dashboardRevision then return
    if m.resolutionTask <> invalid and m.resolutionTask.revision = result.revision then m.resolutionTask = invalid
    if not m.recovery.active or m.dashboardMetric.width <> invalid then return
    quality = dashboardVideoMetrics(result)
    if quality.width = invalid then return
    m.dashboardMetric.width = quality.width
    m.dashboardMetric.height = quality.height
    print "[MEDIA] encoded picture width="; quality.width; " height="; quality.height
    publishPlayerTelemetry(m.video.state)
end sub

sub onAudioRepairDimensions(event as object)
    applyAudioRepairDimensions(event.GetData())
end sub

sub applyAudioRepairDimensions(result as dynamic)
    if GetInterface(result, "ifAssociativeArray") = invalid then return
    if not m.recovery.active or not m.audioRepairActive then return
    if m.currentIndex < 0 or m.top.playlist = invalid then return
    if m.currentIndex >= m.top.playlist.Count() then return
    if result.sourceUrl <> m.top.playlist[m.currentIndex].url then return
    if m.dashboardPlayingSegmentKnown then return
    quality = dashboardVideoMetrics(result)
    if quality.width = invalid then return
    m.dashboardMetric.width = quality.width
    m.dashboardMetric.height = quality.height
    publishPlayerTelemetry(m.video.state)
end sub
