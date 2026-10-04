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
    m.lastSyncAt = 0.0
    m.sync = invalid
    while not m.top.shutdown
        now = dashboardNow()
        if m.snapshot <> invalid and now >= m.retryAt
            if m.sessionToken = "" or now >= m.renewAt
                if m.sync <> invalid then m.sync.AsyncCancel()
                m.sync = invalid
                m.sessionToken = ""
                dashboardAuthenticate()
            end if
            if m.sessionToken <> "" and m.sync = invalid and now - m.lastSyncAt >= 2000
                dashboardSync()
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
            dashboardSyncResponse(ev)
        end if
        if m.sync <> invalid and dashboardNow() - m.syncStarted > 15000 then dashboardDisconnect()
    end while
    if m.sync <> invalid then m.sync.AsyncCancel()
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
    if not req.AsyncPostFromString(FormatJson(dashboardWire(data)))
        print "CONTROL_ROOM auth send failed " + path
        return invalid
    end if
    ev = wait(15000, port)
    if type(ev) <> "roUrlEvent"
        req.AsyncCancel()
        print "CONTROL_ROOM auth timeout " + path
        return invalid
    end if
    if ev.GetResponseCode() <> 200
        print "CONTROL_ROOM auth HTTP " + path + " " + Str(ev.GetResponseCode())
        return invalid
    end if
    print "CONTROL_ROOM auth HTTP " + path + " 200"
    return ParseJson(ev.GetString())
end function

sub dashboardAuthenticate()
    m.top.connectionState = "authenticating"
    challenge = dashboardAuthPost("/device/auth/challenge", {})
    if challenge = invalid or challenge.nonce = invalid
        print "CONTROL_ROOM challenge response invalid"
        dashboardDisconnect()
        return
    end if
    store = CreateObject("roChannelStore")
    proof = store.GetDeviceAttestation(challenge.nonce)
    if proof = invalid
        print "CONTROL_ROOM attestation invalid"
        dashboardDisconnect()
        return
    end if
    if GetInterface(proof, "ifAssociativeArray") = invalid
        print "CONTROL_ROOM attestation unexpected type " + type(proof)
        dashboardDisconnect()
        return
    end if
    token = dashboardText(proof.token)
    if proof.status <> 0 or token = ""
        print "CONTROL_ROOM attestation status " + dashboardText(proof.status) + " token-length " + Str(token.Len())
        dashboardDisconnect()
        return
    end if
    print "CONTROL_ROOM attestation accepted locally"
    session = dashboardAuthPost("/device/auth/session", { challengeId: challenge.challengeId, attestation: token, appSessionId: m.snapshot.appSessionId })
    if session = invalid or session.sessionToken = invalid
        print "CONTROL_ROOM session response invalid"
        dashboardDisconnect()
        return
    end if
    m.sessionToken = session.sessionToken
    m.renewAt = dashboardNow() + 840000
    m.lastSyncAt = 0
    m.backoff = 1000
    m.retryAt = 0
    m.top.connectionState = "connected"
    print "CONTROL_ROOM connected"
end sub

sub dashboardSync()
    batch = []
    for each result in m.queue
        batch.Push(result)
    end for
    m.sync = dashboardTransfer("/device/sync", m.sessionToken, m.port)
    m.sentCount = batch.Count()
    m.syncStarted = dashboardNow()
    m.lastSyncAt = m.syncStarted
    if not m.sync.AsyncPostFromString(FormatJson(dashboardWire({ snapshot: m.snapshot, results: batch }))) then dashboardDisconnect()
end sub

sub dashboardSyncResponse(ev as object)
    if m.sync = invalid then return
    if ev.GetSourceIdentity() <> m.sync.GetIdentity() then return
    code = ev.GetResponseCode()
    m.sync = invalid
    if code <> 200
        print "CONTROL_ROOM sync HTTP " + Str(code)
        dashboardDisconnect()
        return
    end if
    for i = 1 to m.sentCount
        if m.queue.Count() > 0 then m.queue.Shift()
    end for
    data = ParseJson(ev.GetString())
    if data <> invalid and data.command <> invalid then m.top.incoming = data.command
end sub

sub dashboardDisconnect()
    if m.sync <> invalid then m.sync.AsyncCancel()
    m.sync = invalid
    m.sessionToken = ""
    m.top.connectionState = "reconnecting"
    m.retryAt = dashboardNow() + m.backoff + Rnd(1000)
    m.backoff = m.backoff * 2
    if m.backoff > 30000 then m.backoff = 30000
end sub
