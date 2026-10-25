function resolutionSafeSegment(url as string, sourceUrl as string) as boolean
    lower = LCase(url)
    if lower.Left(7) <> "http://" and lower.Left(8) <> "https://" then return false
    ' Never reopen a channel's entry URL or an unbounded /live/ transport.
    if url = sourceUrl or lower.Instr("/live/") >= 0 then return false
    path = lower.Split("?")[0].Split("#")[0]
    return path.Right(3) = ".ts" or path.Right(4) = ".m4s" or path.Right(4) = ".mp4"
end function

' Stat can return an empty AA while AsyncGetToFile has not created its file.
' Only compare a validated size; missing metadata must never halt the Task.
function resolutionPrefixLength(stat as dynamic) as integer
    if GetInterface(stat, "ifAssociativeArray") = invalid then return 0
    if GetInterface(stat.size, "ifInt") = invalid then return 0
    length = stat.size.GetInt()
    if length <= 0 then return 0
    if length > 131072 then return 131072
    return length
end function
