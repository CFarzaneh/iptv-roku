' Pure recovery policy. Times are monotonic seconds, supplied by the caller.
function newPlaybackRecovery(now as double) as object
    return { active: true, attempts: 0, everPlayed: false, pending: false,
        dueAt: -1, reason: "", healthySince: -1, bufferSince: -1,
        lastProgressAt: now, lastPosition: -1, lastMarker: "", hasProgress: false,
        attemptStarted: now, lastState: "none" }
end function

sub recoveryBeginAttempt(recovery as object, now as double)
    recovery.pending = false
    recovery.dueAt = -1
    recovery.healthySince = -1
    recovery.bufferSince = -1
    recovery.lastProgressAt = now
    recovery.lastPosition = -1
    recovery.lastMarker = ""
    recovery.hasProgress = false
    recovery.attemptStarted = now
    recovery.lastState = "none"
end sub

sub recoveryCancel(recovery as object)
    recovery.active = false
    recovery.pending = false
    recovery.dueAt = -1
end sub

sub recoveryObserve(recovery as object, state as string, position as dynamic, now as double, marker = "" as string)
    if not recovery.active then return
    if position = invalid then position = -1
    if state = "playing"
        recovery.everPlayed = true
        recovery.bufferSince = -1
        progressed = (position >= 0 and recovery.lastPosition >= 0 and Abs(position - recovery.lastPosition) > 0.05)
        if marker <> "" and recovery.lastMarker <> "" and marker <> recovery.lastMarker then progressed = true
        gapLimit = 5
        if marker <> "" then gapLimit = 15
        if recovery.lastState <> "playing" or progressed
            if recovery.lastState <> "playing" or now - recovery.lastProgressAt > gapLimit then recovery.healthySince = -1
            recovery.lastProgressAt = now
            recovery.pending = false
            recovery.dueAt = -1
        end if
        if progressed
            recovery.hasProgress = true
            if recovery.healthySince < 0 then recovery.healthySince = now
            if now - recovery.healthySince >= 60 then recovery.attempts = 0
        else if now - recovery.lastProgressAt > gapLimit
            recovery.healthySince = -1
        end if
        recovery.lastPosition = position
        recovery.lastMarker = marker
    else
        recovery.healthySince = -1
        if state = "buffering"
            if recovery.bufferSince < 0 then recovery.bufferSince = now
        else
            recovery.bufferSince = -1
        end if
        if state = "paused"
            recovery.pending = false
            recovery.dueAt = -1
            recovery.lastProgressAt = now
            recovery.lastPosition = position
        end if
    end if
    recovery.lastState = state
end sub

function recoveryRequest(recovery as object, limit as integer, reason as string, now as double) as boolean
    if not recovery.active then return false
    if limit <= 0 then return false
    if recovery.pending then return true
    if recovery.attempts >= limit or recovery.attempts >= 3 then return false
    delays = [1, 3, 8]
    recovery.pending = true
    recovery.reason = reason
    recovery.dueAt = now + delays[recovery.attempts]
    recovery.healthySince = -1
    return true
end function

function recoveryTakeRetry(recovery as object, now as double) as boolean
    if not recovery.active or not recovery.pending or now < recovery.dueAt then return false
    recovery.attempts = recovery.attempts + 1
    recoveryBeginAttempt(recovery, now)
    return true
end function

function recoveryStallReason(recovery as object, state as string, now as double) as string
    if not recovery.active or recovery.pending then return ""
    if state = "paused" or state = "error" then return ""
    if state = "finished" then return "live-end"
    if state = "buffering" and recovery.bufferSince >= 0
        if now - recovery.bufferSince >= 30 then return "buffering"
    else if state = "playing" and recovery.hasProgress
        if now - recovery.lastProgressAt >= 30 then return "stalled"
    else if state = "none" or state = "stopped"
        if now - recovery.attemptStarted >= 30 then return "startup"
    end if
    return ""
end function

function recoveryHttpStatus(detail as string) as integer
    ' Anchor to diagnostic labels, never arbitrary numbers in IDs or media URLs.
    pattern = "(response code[^0-9]{0,60}|http[ :=()]+|last_err:|lasterror:)([1-5][0-9][0-9])([^0-9]|$)"
    matches = CreateObject("roRegex", pattern, "i").Match(detail)
    if matches.Count() >= 3 then return Val(matches[2])
    return 0
end function

function recoveryErrorLimit(code as integer, category as string, detail as string, everPlayed as boolean) as integer
    detail = LCase(detail)
    http = recoveryHttpStatus(detail)
    if http = 401 or http = 403 then return 0
    if code = -4 or code = -6 or LCase(category) = "drm" then return 0
    for each permanent in ["unsupported aac stream", "unsupported codec", "codec not supported", "unsupported video", "unsupported audio", "invalid url", "empty list", "no streams specified", "unauthorized", "forbidden", "access denied", "certificate"]
        if Instr(1, detail, permanent) > 0 then return 0
    end for
    if http = 408 or http = 429 or http = 500 or http = 502 or http = 503 or http = 504 then return 3
    if http = 404
        if everPlayed then return 1
        return 0
    end if
    if http >= 400 then return 0
    if code = -2 then return 3
    for each temporary in ["timed out", "timeout", "connection reset", "connection refused", "could not connect", "couldn't connect", "could not resolve", "couldn't resolve", "network is unreachable", "network error"]
        if Instr(1, detail, temporary) > 0 then return 3
    end for
    ' Unknown HTTP/media/parser errors get one conservative restart only after
    ' this channel has demonstrated it can play. Explicit server errors get 3.
    if everPlayed and (code = -1 or code = -3 or code = -5) then return 1
    return 0
end function
