sub init()
    m.top.functionName = "validateProvider"
end sub

sub validateProvider()
    candidate = m.top.candidate
    req = CreateObject("roUrlTransfer")
    server = dashboardText(candidate.server).Trim()
    if not server.StartsWith("https://") and not server.StartsWith("http://")
        m.top.result = { ok: false, code: "PROVIDER_ERROR" }
        return
    end if
    while server.EndsWith("/")
        server = server.Left(server.Len() - 1)
    end while
    url = server
    if candidate.providerType = "xtream"
        url = server + "/player_api.php?username=" + req.Escape(candidate.username) + "&password=" + req.Escape(candidate.password)
    end if
    port = CreateObject("roMessagePort")
    req.SetMessagePort(port)
    req.SetUrl(url)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.InitClientCertificates()
    req.EnablePeerVerification(true)
    req.EnableHostVerification(true)
    req.EnableEncodings(true)
    ' Match catalog and playback requests; some providers reject default clients.
    req.AddHeader("User-Agent", "Mozilla/5.0")
    if not req.AsyncGetToString()
        m.top.result = { ok: false, code: "PROVIDER_CONNECTION_FAILED" }
        return
    end if
    ev = wait(30000, port)
    if type(ev) <> "roUrlEvent"
        req.AsyncCancel()
        m.top.result = { ok: false, code: "PROVIDER_CONNECTION_FAILED" }
        return
    end if
    httpCode = ev.GetResponseCode()
    code = providerValidationCode(httpCode, ev.GetString(), candidate.providerType)
    ' Local diagnostic includes no URL, username, password or server error body.
    print "CONTROL_ROOM provider validation HTTP " + httpCode.ToStr() + " " + code
    m.top.result = { ok: code = "NONE", code: code }
end sub
