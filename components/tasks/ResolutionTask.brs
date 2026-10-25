sub init()
    m.top.functionName = "inspectResolution"
end sub

sub inspectResolution()
    result = { revision: m.top.revision }
    outcome = "skipped"
    m.resolutionHttpCode = 0
    sampleBytes = 0
    if not m.top.cancel and resolutionSafeSegment(m.top.segmentUrl, m.top.sourceUrl)
        bytes = readResolutionPrefix()
        sampleBytes = bytes.Count()
        outcome = "unavailable"
        if not m.top.cancel and bytes.Count() > 0
            outcome = "unsupported-or-incomplete"
            parsed = resolutionFromBytes(bytes, m.top.codecHint)
            if parsed.width <> invalid
                result.width = parsed.width
                result.height = parsed.height
                outcome = "detected"
            end if
        end if
    end if
    if not m.top.cancel then print "[MEDIA] resolution sample outcome="; outcome; " bytes="; sampleBytes; " http="; m.resolutionHttpCode
    m.top.result = result
end sub

function readResolutionPrefix() as object
    bytes = CreateObject("roByteArray")
    path = "tmp:/picture-size-" + m.top.revision.ToStr() + "-" + m.top.attempt.ToStr() + ".bin"
    DeleteFile(path)
    req = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    req.SetMessagePort(port)
    req.SetUrl(m.top.segmentUrl)
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    req.EnablePeerVerification(true)
    req.EnableHostVerification(true)
    req.AddHeader("User-Agent", "Mozilla/5.0")
    req.AddHeader("Range", "bytes=0-131071")
    if req.AsyncGetToFile(path)
        fs = CreateObject("roFileSystem")
        clock = CreateObject("roTimespan")
        clock.Mark()
        usable = false
        complete = false
        while not m.top.cancel and clock.TotalMilliseconds() < 5000
            ev = wait(100, port)
            if Type(ev) = "roUrlEvent" and ev.GetSourceIdentity() = req.GetIdentity()
                code = ev.GetResponseCode()
                m.resolutionHttpCode = code
                usable = (code = 200 or code = 206)
                complete = true
                exit while
            end if
            stat = fs.Stat(path)
            if stat <> invalid and stat.size >= 131072
                ' A segment server may ignore Range. Cancel once enough bytes
                ' arrive; parsing/file reads stay capped at 128 KiB.
                usable = true
                exit while
            end if
        end while
        if not complete then req.AsyncCancel()
        if usable and not m.top.cancel
            stat = fs.Stat(path)
            if stat <> invalid and stat.size > 0
                length = stat.size
                if length > 131072 then length = 131072
                bytes.ReadFile(path, 0, length)
            end if
        end if
    end if
    DeleteFile(path)
    return bytes
end function
