' Catalog IDs are scoped by content kind. Episodes can use the same playback
' fields with their own kind, while a series itself remains a browse item.
function onDemandText(value as dynamic) as string
    if GetInterface(value, "ifString") <> invalid then return value.Trim()
    if GetInterface(value, "ifInt") <> invalid or GetInterface(value, "ifLongInt") <> invalid then return value.ToStr().Trim()
    return ""
end function

function isOnDemand(item as dynamic) as boolean
    if GetInterface(item, "ifAssociativeArray") = invalid then return false
    return item.mediaKind = "movie" or item.mediaKind = "episode"
end function

function onDemandFormat(extension as string) as string
    formats = {mp4: "mp4", m4v: "mp4", mov: "mp4", mkv: "mkv", m3u8: "hls", mpd: "dash"}
    format = formats[LCase(extension)]
    if format = invalid then return ""
    return format
end function

function onDemandMovie(row as dynamic, streamBase as string, category as string, accountScope as string) as dynamic
    if GetInterface(row, "ifAssociativeArray") = invalid then return invalid
    id = onDemandText(row.stream_id)
    title = onDemandText(row.name).Left(200)
    digits = CreateObject("roRegex", "^[0-9]{1,32}$", "")
    if not digits.IsMatch(id) or title = "" then return invalid

    extension = LCase(onDemandText(row.container_extension))
    format = onDemandFormat(extension)
    url = ""
    if format <> "" then url = streamBase + id + "." + extension
    year = onDemandText(row.year)
    if year = "" then year = onDemandText(row.releaseDate).Left(4)
    if not CreateObject("roRegex", "^[0-9]{4}$", "").IsMatch(year) then year = ""
    description = onDemandText(row.plot).Left(350)
    logo = onDemandText(row.stream_icon).Left(2048)
    scheme = LCase(logo)
    if scheme.Left(7) <> "http://" and scheme.Left(8) <> "https://" then logo = ""
    return {
        mediaKind: "movie", mediaId: id, resumeKey: accountScope + ":movie:" + id,
        name: title, group: category, logo: logo,
        year: year, description: description,
        url: url, streamFormat: format, compatible: format <> ""
    }
end function
