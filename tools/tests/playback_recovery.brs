' brs --root tools/tests source/PlaybackRecovery.brs tools/tests/playback_recovery.brs
sub main()
    m.checks = 0
    check(recoveryErrorLimit(-1, "http", "HTTP response code said error response code:(500):500", false) = 3, "observed HTTP 500")
    check(recoveryErrorLimit(-5, "mediaerror", "Errors seen on all bitrates:last_err:500:extra:content_id:3", false) = 3, "observed demux error")
    for each status in [408, 429, 500, 502, 503, 504]
        check(recoveryErrorLimit(-1, "http", "response code:(" + status.ToStr() + ")", false) = 3, "transient HTTP")
    end for
    for each status in [400, 401, 403, 410]
        check(recoveryErrorLimit(-1, "http", "response code:(" + status.ToStr() + ")", true) = 0, "permanent HTTP")
    end for
    check(recoveryErrorLimit(-2, "", "", false) = 3, "timeout")
    check(recoveryErrorLimit(-1, "http", "connection reset", false) = 3, "connection reset")
    check(recoveryErrorLimit(-1, "http", "last_err:404", true) = 1, "missing live resource")
    check(recoveryErrorLimit(-1, "http", "last_err:404", false) = 0, "missing initial channel")
    check(recoveryErrorLimit(-5, "mediaerror", "no valid bitrates", true) = 1, "unknown media failure after playback")
    check(recoveryErrorLimit(-5, "mediaerror", "no valid bitrates", false) = 0, "unproven format")
    check(recoveryErrorLimit(-3, "mediaplayer", "reader pick stream error:bad:parsing failed", true) = 1, "transient parser failure")
    check(recoveryErrorLimit(-3, "mediaplayer", "parsing failed", false) = 0, "invalid initial response")
    check(recoveryErrorLimit(-5, "mediaerror", "unsupported aac stream", true) = 0, "AAC repair remains separate")
    check(recoveryErrorLimit(-5, "mediaerror", "unsupported video codec", true) = 0, "unsupported codec")
    check(recoveryErrorLimit(-4, "", "", true) = 0, "empty list")
    check(recoveryErrorLimit(-6, "drm", "timeout", true) = 0, "DRM not restarted blindly")
    check(recoveryErrorLimit(-1, "http", "certificate verification failed", true) = 0, "certificate failure")
    check(recoveryHttpStatus("content_id:500:segment:403:errcode:9") = 0, "IDs are not HTTP statuses")

    r = newPlaybackRecovery(0)
    check(recoveryRequest(r, 3, "error", 10), "first request")
    check(r.dueAt = 11 and r.attempts = 0, "one-second delay, count only actual restart")
    check(not recoveryTakeRetry(r, 10.9), "not early")
    check(recoveryTakeRetry(r, 11) and r.attempts = 1, "first restart")
    check(recoveryRequest(r, 3, "error", 12) and r.dueAt = 15, "three-second delay")
    check(recoveryRequest(r, 3, "error", 13) and r.dueAt = 15, "duplicate error does not move deadline")
    check(not recoveryRequest(r, 0, "error", 13), "permanent error overrides pending recovery")
    check(recoveryTakeRetry(r, 15) and r.attempts = 2, "second restart")
    check(recoveryRequest(r, 3, "error", 16) and r.dueAt = 24, "eight-second delay")
    check(recoveryTakeRetry(r, 24) and r.attempts = 3, "third restart")
    check(not recoveryRequest(r, 3, "error", 25), "budget exhausted")

    r = newPlaybackRecovery(0)
    r.attempts = 2
    recoveryObserve(r, "playing", 0, 0)
    for t = 1 to 60
        recoveryObserve(r, "playing", t, t)
    end for
    check(r.attempts = 2, "playing event alone does not reset budget")
    recoveryObserve(r, "playing", 61, 61)
    check(r.attempts = 0, "reset after sixty seconds of progressing playback")

    r = newPlaybackRecovery(0)
    r.attempts = 2
    for t = 0 to 120
        state = "playing"
        if t mod 20 = 0 then state = "buffering"
        recoveryObserve(r, state, t, t)
    end for
    check(r.attempts = 2, "short recoveries do not create an infinite loop")

    r = newPlaybackRecovery(0)
    r.attempts = 2
    recoveryObserve(r, "playing", 0, 0)
    recoveryObserve(r, "playing", 1, 1)
    for t = 2 to 60
        recoveryObserve(r, "playing", 1, t)
    end for
    check(r.attempts = 2, "frozen player never earns healthy reset")
    check(recoveryStallReason(r, "playing", 60) = "stalled", "frozen position watchdog")
    check(recoveryRequest(r, 3, "stalled", 60), "stalled playing can reconnect")
    recoveryObserve(r, "playing", 1, 61)
    check(r.pending and recoveryTakeRetry(r, 68), "unchanged playing state does not cancel stall recovery")

    r = newPlaybackRecovery(0)
    recoveryObserve(r, "playing", invalid, 0)
    recoveryObserve(r, "playing", invalid, 60)
    check(recoveryStallReason(r, "playing", 60) = "", "missing telemetry cannot trigger false reconnects")
    r.attempts = 2
    for t = 0 to 72 step 6
        recoveryObserve(r, "playing", invalid, t, Int(t / 6).ToStr())
    end for
    check(r.attempts = 0, "playing segment progress supports sources without position")

    r = newPlaybackRecovery(0)
    recoveryObserve(r, "buffering", 0, 0)
    check(recoveryStallReason(r, "buffering", 29.9) = "", "ordinary buffering allowed")
    check(recoveryStallReason(r, "buffering", 30) = "buffering", "thirty-second buffering watchdog")
    check(recoveryRequest(r, 3, "buffering", 30), "buffering recovery scheduled")
    recoveryObserve(r, "playing", 1, 30.5)
    check(not r.pending and not recoveryTakeRetry(r, 31), "natural recovery cancels restart")
    check(r.attempts = 0, "cancelled recovery consumes no budget")

    r = newPlaybackRecovery(0)
    r.attempts = 2
    for t = 0 to 120
        recoveryObserve(r, "paused", 10, t)
    end for
    check(recoveryStallReason(r, "paused", 120) = "" and r.attempts = 2, "pause does not trigger retries or reset budget")
    check(recoveryStallReason(r, "finished", 120) = "live-end", "unexpected live EOF")
    check(recoveryStallReason(r, "stopped", 120) = "startup", "unexpected stopped player")
    check(recoveryRequest(r, 3, "error", 121), "pending exit test")
    recoveryCancel(r)
    check(not recoveryTakeRetry(r, 500) and recoveryStallReason(r, "finished", 500) = "", "exit prevents resurrection")
    r = newPlaybackRecovery(500)
    check(not recoveryTakeRetry(r, 500) and r.attempts = 0, "new channel discards old deadline")
    print "Playback recovery checks passed: "; m.checks
end sub

sub check(condition as boolean, label as string)
    m.checks = m.checks + 1
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
