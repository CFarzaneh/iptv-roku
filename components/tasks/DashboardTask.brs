sub init()
    m.top.functionName = "dashboardRun"
end sub

sub dashboardRun()
    fs = CreateObject("roFileSystem")
    if not fs.Exists("pkg:/source/dashboard.json") then return
    cfg = ParseJson(ReadAsciiFile("pkg:/source/dashboard.json"))
    if cfg = invalid then return
    m.apiUrl = dashboardText(cfg.apiUrl)
    m.installationSecret = dashboardText(cfg.secret)
    if not m.apiUrl.StartsWith("https://") or m.installationSecret.Len() < 40 then return
    while m.apiUrl.EndsWith("/")
        m.apiUrl = m.apiUrl.Left(m.apiUrl.Len() - 1)
    end while
    m.port = CreateObject("roMessagePort")
    m.top.observeField("snapshot", m.port)
    m.top.observeField("outgoing", m.port)
    m.top.observeField("shutdown", m.port)
    m.snapshot = m.top.snapshot
    m.queue = []
    m.sessionToken = ""
    m.renewAt = 0.0
    m.retryAt = 0.0
    m.backoff = 1000.0
    m.lastReportAt = 0.0
    m.poll = invalid
    m.post = invalid
    m.firstReport = true
    while not m.top.shutdown
        now = dashboardNow()
        if m.snapshot <> invalid and now >= m.retryAt
            if m.sessionToken = "" or now >= m.renewAt
                if m.poll <> invalid then m.poll.AsyncCancel()
                if m.post <> invalid then m.post.AsyncCancel()
                m.poll = invalid
                m.post = invalid
                m.sessionToken = ""
                dashboardAuthenticate()
            end if
            if m.sessionToken <> ""
                if m.post = invalid
                    if m.firstReport or now - m.lastReportAt >= 5000
                        dashboardPost("/device/reports", m.snapshot, "report")
                        m.lastReportAt = now
                    else if m.queue.Count() > 0
                        dashboardPost("/device/results", m.queue.Shift(), "result")
                    end if
                end if
                if m.poll = invalid and not m.firstReport
                    m.poll = dashboardTransfer("/device/commands", m.sessionToken, m.port)
                    m.pollStarted = now
                    if not m.poll.AsyncGetToString() then dashboardDisconnect()
                end if
            end if
        end if
        ev = wait(100, m.port)
        if type(ev) = "roSGNodeEvent"
            if ev.GetField() = "snapshot"
                m.snapshot = ev.GetData()
            else if ev.GetField() = "outgoing"
                if m.queue.Count() < 24 then m.queue.Push(ev.GetData())
            end if
        else if type(ev) = "roUrlEvent"
            dashboardResponse(ev)
        end if
        now = dashboardNow()
        if m.poll <> invalid
            if now - m.pollStarted > 35000 then dashboardDisconnect()
        end if
        if m.post <> invalid
            if now - m.postStarted > 15000 then dashboardDisconnect()
        end if
    end while
    if m.poll <> invalid then m.poll.AsyncCancel()
    if m.post <> invalid then m.post.AsyncCancel()
end sub

function dashboardTransfer(path as string, token as string, port as object) as object
    req = CreateObject("roUrlTransfer")
    req.SetMessagePort(port)
    req.SetUrl(m.apiUrl + path)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.EnablePeerVerification(true)
    req.EnableHostVerification(true)
    req.AddHeader("Authorization", "Bearer " + token)
    req.AddHeader("Content-Type", "application/json")
    req.RetainBodyOnError(false)
    return req
end function

function dashboardAuthPost(path as string, data as object) as dynamic
    port = CreateObject("roMessagePort")
    req = dashboardTransfer(path, m.installationSecret, port)
    if not req.AsyncPostFromString(FormatJson(data)) then return invalid
    ev = wait(15000, port)
    if type(ev) <> "roUrlEvent"
        req.AsyncCancel()
        return invalid
    end if
    if ev.GetResponseCode() <> 200 then return invalid
    return ParseJson(ev.GetString())
end function

sub dashboardAuthenticate()
    m.top.connectionState = "authenticating"
    challenge = dashboardAuthPost("/device/auth/challenge", {})
    if challenge = invalid or challenge.nonce = invalid
        dashboardDisconnect()
        return
    end if
    store = CreateObject("roChannelStore")
    proof = store.GetDeviceAttestation(challenge.nonce)
    if proof = invalid or proof = ""
        dashboardDisconnect()
        return
    end if
    session = dashboardAuthPost("/device/auth/session", { challengeId: challenge.challengeId, attestation: proof, appSessionId: m.snapshot.appSessionId })
    if session = invalid or session.sessionToken = invalid
        dashboardDisconnect()
        return
    end if
    m.sessionToken = session.sessionToken
    m.renewAt = dashboardNow() + 840000
    m.firstReport = true
    m.backoff = 1000
    m.retryAt = 0
    m.top.connectionState = "connected"
end sub

sub dashboardPost(path as string, body as object, kind as string)
    m.post = dashboardTransfer(path, m.sessionToken, m.port)
    m.postKind = kind
    m.postStarted = dashboardNow()
    if not m.post.AsyncPostFromString(FormatJson(body)) then dashboardDisconnect()
end sub

sub dashboardResponse(ev as object)
    code = ev.GetResponseCode()
    if m.poll <> invalid
        if ev.GetSourceIdentity() = m.poll.GetIdentity()
            m.poll = invalid
            if code = 200
                data = ParseJson(ev.GetString())
                if data <> invalid and data.commands <> invalid
                    for each command in data.commands
                        m.top.incoming = command
                    end for
                end if
            else
                dashboardDisconnect()
            end if
            return
        end if
    end if
    if m.post <> invalid
        if ev.GetSourceIdentity() = m.post.GetIdentity()
            m.post = invalid
            if code = 200
                if m.postKind = "report" then m.firstReport = false
            else if code <> 409
                dashboardDisconnect()
            end if
        end if
    end if
end sub

sub dashboardDisconnect()
    if m.poll <> invalid then m.poll.AsyncCancel()
    if m.post <> invalid then m.post.AsyncCancel()
    m.poll = invalid
    m.post = invalid
    m.sessionToken = ""
    m.top.connectionState = "reconnecting"
    m.retryAt = dashboardNow() + m.backoff + Rnd(1000)
    m.backoff = m.backoff * 2
    if m.backoff > 30000 then m.backoff = 30000
end sub
