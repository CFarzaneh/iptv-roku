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

function dashboardFormatOSVersion(version as dynamic) as string
    if GetInterface(version, "ifAssociativeArray") = invalid then return ""
    major = dashboardText(version.major)
    minor = dashboardText(version.minor)
    revision = dashboardText(version.revision)
    build = dashboardText(version.build)
    digits = CreateObject("roRegex", "^[0-9]+$", "")
    if not digits.IsMatch(major) or not digits.IsMatch(minor) then return ""
    result = major + "." + minor
    if digits.IsMatch(revision) then result = result + "." + revision
    if digits.IsMatch(build) then result = result + " (build " + build + ")"
    return result
end function

function dashboardPositiveNumber(value as dynamic) as boolean
    valueType = LCase(Type(value))
    if valueType <> "integer" and valueType <> "roint" and valueType <> "longinteger" and valueType <> "rolonginteger" and valueType <> "float" and valueType <> "rofloat" and valueType <> "double" and valueType <> "rodouble" then return false
    return value > 0
end function

' Only video or mux metadata describes picture quality. Audio/caption events
' must not clear resolution or overwrite the video bitrate with e.g. 128 kbps.
function dashboardVideoMetrics(segment as dynamic) as object
    result = {}
    if GetInterface(segment, "ifAssociativeArray") = invalid then return result
    if segment.segType = 1 or segment.segType = 3 then return result
    if segment.segType <> invalid and segment.segType <> 0 and segment.segType <> 2 then return result
    width = segment.width
    height = segment.height
    if dashboardPositiveNumber(width) and dashboardPositiveNumber(height)
        if width <= 16384 and height <= 16384 and Fix(width) = width and Fix(height) = height
            result.width = width
            result.height = height
        end if
    end if
    bitrate = segment.segBitrateBps
    if not dashboardPositiveNumber(bitrate) then bitrate = segment.bitrateBps
    if dashboardPositiveNumber(bitrate) then result.bitrate = bitrate
    return result
end function

function dashboardNow() as double
    ' The # suffix keeps epoch milliseconds in double precision. A Float
    ' rounds current timestamps into intervals of roughly two minutes.
    return CreateObject("roDateTime").AsSeconds() * 1000#
end function

' BrightScript's unquoted associative-array keys become lowercase. Restore the
' API's JSON field names at the network boundary, including nested telemetry.
function dashboardWire(value as dynamic) as dynamic
    if value = invalid then return invalid
    if GetInterface(value, "ifArray") <> invalid
        entries = []
        for each entry in value
            entries.Push(dashboardWire(entry))
        end for
        return entries
    end if
    if GetInterface(value, "ifAssociativeArray") <> invalid
        names = {
            appsessionid: "appSessionId", challengeid: "challengeId",
            sourcerevision: "sourceRevision", catalogrevision: "catalogRevision",
            playbackrevision: "playbackRevision", streamid: "streamId",
            commandid: "commandId", appversion: "appVersion", osversion: "osVersion",
            sessionbytes: "sessionBytes", tunebytes: "tuneBytes",
            bytespersecond: "bytesPerSecond", startupms: "startupMs",
            bufferingcount: "bufferingCount", bufferingms: "bufferingMs"
        }
        result = {}
        for each key in value
            wireKey = names[LCase(key)]
            if wireKey = invalid then wireKey = key
            result[wireKey] = dashboardWire(value[key])
        end for
        return result
    end if
    return value
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
