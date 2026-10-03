sub init()
    m.top.functionName = "validateProvider"
end sub

sub validateProvider()
    candidate = m.top.candidate
    req = CreateObject("roUrlTransfer")
    server = dashboardText(candidate.server)
    if not server.StartsWith("https://") and not server.StartsWith("http://")
        m.top.result = { ok: false }
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
    req.EnablePeerVerification(true)
    req.EnableHostVerification(true)
    req.EnableEncodings(true)
    if not req.AsyncGetToString()
        m.top.result = { ok: false }
        return
    end if
    ev = wait(30000, port)
    if type(ev) <> "roUrlEvent"
        req.AsyncCancel()
        m.top.result = { ok: false }
        return
    end if
    if ev.GetResponseCode() <> 200 or ev.GetString().Len() > 20000000
        m.top.result = { ok: false }
        return
    end if
    body = ev.GetString()
    ok = false
    if candidate.providerType = "xtream"
        data = ParseJson(body)
        if data <> invalid and data.user_info <> invalid
            ok = (dashboardText(data.user_info.auth) = "1" and LCase(dashboardText(data.user_info.status)) = "active")
        end if
    else
        parsed = ParseM3U(body)
        ok = (parsed.channels.Count() > 0)
    end if
    m.top.result = { ok: ok }
end sub
