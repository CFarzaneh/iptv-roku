' brs --root tools/tests source/DashboardModel.brs components/PlayerTelemetry.brs tools/tests/dashboard_telemetry.brs
sub main()
    check(dashboardFormatOSVersion({major: "15", minor: "3", revision: "4", build: "2303"}) = "15.3.4 (build 2303)", "OS version")
    check(dashboardFormatOSVersion({major: "15", minor: "3"}) = "15.3", "partial OS version")
    check(dashboardFormatOSVersion(invalid) = "", "missing OS version")
    check(dashboardFormatOSVersion({major: "bad", minor: "3"}) = "", "malformed OS version")

    m.dashboardMetric = dashboardEmptyMetrics()
    dashboardApplyVideoMetrics({segType: 2, width: 1280, height: 720, segBitrateBps: 3000000})
    check(m.dashboardMetric.width = 1280 and m.dashboardMetric.height = 720, "playing segment resolution")
    check(m.dashboardMetric.bitrate = 3000000, "video bitrate")
    dashboardApplyVideoMetrics({SegType: 1, Width: 100, Height: 100, BitrateBPS: 128000})
    check(m.dashboardMetric.width = 1280 and m.dashboardMetric.bitrate = 3000000, "audio cannot replace video quality")
    dashboardApplyVideoMetrics({SegType: 3, BitrateBPS: 1000})
    dashboardApplyVideoMetrics(invalid)
    dashboardApplyVideoMetrics({SegType: 2, Width: 1920, Height: invalid})
    dashboardApplyVideoMetrics({SegType: 2, Width: "1920", Height: "1080"})
    dashboardApplyVideoMetrics({SegType: 2, Width: 99999, Height: 1080})
    check(m.dashboardMetric.width = 1280 and m.dashboardMetric.height = 720, "missing/malformed dimensions preserve last complete pair")
    dashboardApplyVideoMetrics({SegType: 0, Width: 1920, Height: 1080, BitrateBPS: 6000000})
    check(m.dashboardMetric.width = 1920 and m.dashboardMetric.height = 1080, "mux segment fallback")

    m.dashboardPlayingSegmentKnown = false
    event = {GetData: function() as object
        return {Status: 0, SegType: 2, Width: 2560, Height: 1440}
    end function}
    onDashboardSegment(event)
    check(m.dashboardMetric.width = 2560, "missing byte count does not suppress resolution")
    event = {GetData: function() as object
        return {segType: 2, width: 3840, height: 2160, segBitrateBps: 15000000}
    end function}
    onDashboardStreamingSegment(event)
    check(m.dashboardMetric.width = 3840 and m.dashboardPlayingSegmentKnown, "playing representation takes priority")
    event = {GetData: function() as object
        return {Status: 0, SegType: 2, Width: 1920, Height: 1080}
    end function}
    onDashboardSegment(event)
    check(m.dashboardMetric.width = 3840, "prefetched representation cannot replace playing resolution")
    m.top = {dashboardCommandId: ""}
    m.dashboardRevision = 0
    m.dashboardBytesKnown = false
    dashboardBeginTune({providerStreamId: "123", name: "New channel"})
    check(m.dashboardMetric.width = invalid and m.dashboardMetric.height = invalid, "new tune clears old resolution")
    check(not m.dashboardPlayingSegmentKnown, "new tune enables download fallback again")
    onDashboardSegment(event)
    check(m.dashboardMetric.width = 1920, "new channel reports its own resolution")
    print "Dashboard telemetry checks passed"
end sub

' A deterministic clock for off-device tests; production uses Roku's Uptime.
function Uptime(_unused as integer) as double
    return 100#
end function

sub check(condition as boolean, label as string)
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
