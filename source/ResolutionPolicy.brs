function resolutionSafeSegment(url as string, sourceUrl as string) as boolean
    lower = LCase(url)
    if lower.Left(7) <> "http://" and lower.Left(8) <> "https://" then return false
    ' Never reopen a channel's entry URL or an unbounded /live/ transport.
    if url = sourceUrl or lower.Instr("/live/") >= 0 then return false
    path = lower.Split("?")[0].Split("#")[0]
    return path.Right(3) = ".ts" or path.Right(4) = ".m4s" or path.Right(4) = ".mp4"
end function
