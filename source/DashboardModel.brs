' Shared helpers; no provider URLs are returned in public channel metadata.
function dashboardText(value as dynamic) as string
    if value = invalid then return ""
    if GetInterface(value, "ifString") <> invalid then return value
    if GetInterface(value, "ifInt") <> invalid then return value.ToStr()
    return ""
end function

function dashboardUuid() as string
    return CreateObject("roDeviceInfo").GetRandomUUID()
end function

function dashboardNow() as double
    return CreateObject("roDateTime").AsSeconds() * 1000.0
end function

function dashboardChannelId(channel as object) as string
    if channel.providerStreamId <> invalid then return dashboardText(channel.providerStreamId)
    return dashboardText(channel.dashboardId)
end function

function dashboardChannel(channel as dynamic) as dynamic
    if channel = invalid then return invalid
    return { streamId: dashboardChannelId(channel), name: dashboardText(channel.name).Left(200), group: dashboardText(channel.group).Left(200) }
end function

sub dashboardAssignM3uIds(channels as object)
    counts = {}
    for each channel in channels
        guideId = dashboardText(channel.tvgId)
        if guideId <> ""
            if counts[guideId] = invalid then counts[guideId] = 0
            counts[guideId] = counts[guideId] + 1
        end if
    end for
    for each channel in channels
        guideId = dashboardText(channel.tvgId)
        if guideId <> "" and counts[guideId] = 1 and guideId.Len() <= 160
            channel.dashboardId = guideId
        else
            channel.dashboardId = "entry-" + dashboardUuid()
        end if
    end for
end sub

function dashboardEmptyMetrics() as object
    return { sessionBytes: invalid, tuneBytes: invalid, bytesPerSecond: invalid, bitrate: invalid, width: invalid, height: invalid, startupMs: invalid, bufferingCount: invalid, bufferingMs: invalid }
end function
