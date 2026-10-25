' Read source picture dimensions without decoding video. Used only on Task threads.
' All scans are bounded; incomplete/encrypted/unsupported input returns no result.
function resolutionPair(width as integer, height as integer, codec as string) as object
    if width < 16 or height < 16 or width > 16384 or height > 16384 then return {}
    return { width: width, height: height, codec: codec }
end function

function resolutionBits(data as object, start as integer, finish as integer) as object
    bytes = []
    zeroes = 0
    for i = start to finish - 1
        b = data[i]
        if zeroes >= 2 and b = 3
            zeroes = 0
        else
            bytes.Push(b)
            if b = 0 then zeroes = zeroes + 1 else zeroes = 0
        end if
    end for
    return { data: bytes, bit: 0, ok: true }
end function

function resolutionRead(r as object, count as integer) as integer
    if not r.ok or count < 0 or count > 24 or r.bit + count > r.data.Count() * 8
        r.ok = false
        return 0
    end if
    value = 0
    for i = 1 to count
        value = value * 2 + (Int(r.data[Int(r.bit / 8)] / (2 ^ (7 - (r.bit mod 8)))) mod 2)
        r.bit = r.bit + 1
    end for
    return value
end function

sub resolutionSkip(r as object, count as integer)
    if count < 0 or r.bit + count > r.data.Count() * 8 then r.ok = false
    r.bit = r.bit + count
end sub

function resolutionUe(r as object) as integer
    zeroes = 0
    while r.ok
        if resolutionRead(r, 1) = 1 then exit while
        zeroes = zeroes + 1
        if zeroes > 16 then r.ok = false
    end while
    if not r.ok then return 0
    return Int(2 ^ zeroes) - 1 + resolutionRead(r, zeroes)
end function

function resolutionSe(r as object) as integer
    value = resolutionUe(r)
    if value mod 2 = 1 then return Int((value + 1) / 2)
    return -Int(value / 2)
end function

function resolutionH264(data as object, start as integer, finish as integer) as object
    if finish - start < 5 or finish - start > 4096 then return {}
    r = resolutionBits(data, start + 1, finish)
    profile = resolutionRead(r, 8)
    resolutionSkip(r, 16)
    resolutionUe(r)
    chroma = 1
    separate = 0
    high = false
    for each p in [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if profile = p then high = true
    end for
    if high
        chroma = resolutionUe(r)
        if chroma > 3 then return {}
        if chroma = 3 then separate = resolutionRead(r, 1)
        resolutionUe(r)
        resolutionUe(r)
        resolutionSkip(r, 1)
        if resolutionRead(r, 1) = 1
            count = 8
            if chroma = 3 then count = 12
            for i = 0 to count - 1
                if resolutionRead(r, 1) = 1
                    size = 16
                    if i >= 6 then size = 64
                    lastScale = 8
                    nextScale = 8
                    for j = 1 to size
                        if nextScale <> 0 then nextScale = (lastScale + resolutionSe(r) + 256) mod 256
                        if nextScale <> 0 then lastScale = nextScale
                    end for
                end if
            end for
        end if
    end if
    resolutionUe(r)
    order = resolutionUe(r)
    if order = 0
        resolutionUe(r)
    else if order = 1
        resolutionSkip(r, 1)
        resolutionSe(r)
        resolutionSe(r)
        cycle = resolutionUe(r)
        if cycle > 256 then return {}
        for i = 1 to cycle
            resolutionSe(r)
        end for
    else if order > 2
        return {}
    end if
    resolutionUe(r)
    resolutionSkip(r, 1)
    widthMbs = resolutionUe(r) + 1
    heightUnits = resolutionUe(r) + 1
    frameOnly = resolutionRead(r, 1)
    if frameOnly = 0 then resolutionSkip(r, 1)
    resolutionSkip(r, 1)
    leftCrop = 0: rightCrop = 0: topCrop = 0: bottomCrop = 0
    if resolutionRead(r, 1) = 1
        leftCrop = resolutionUe(r): rightCrop = resolutionUe(r)
        topCrop = resolutionUe(r): bottomCrop = resolutionUe(r)
    end if
    if not r.ok then return {}
    if separate = 1 then chroma = 0
    cropX = 1
    if chroma = 1 or chroma = 2 then cropX = 2
    cropY = 2 - frameOnly
    if chroma = 1 then cropY = cropY * 2
    return resolutionPair(widthMbs * 16 - cropX * (leftCrop + rightCrop), heightUnits * 16 * (2 - frameOnly) - cropY * (topCrop + bottomCrop), "H.264")
end function

function resolutionHevc(data as object, start as integer, finish as integer) as object
    if finish - start < 15 or finish - start > 4096 then return {}
    r = resolutionBits(data, start + 2, finish)
    resolutionSkip(r, 4)
    layers = resolutionRead(r, 3)
    if layers > 6 then return {}
    resolutionSkip(r, 1)
    resolutionSkip(r, 96)
    profiles = []: levels = []
    for i = 0 to layers - 1
        profiles.Push(resolutionRead(r, 1))
        levels.Push(resolutionRead(r, 1))
    end for
    if layers > 0 then resolutionSkip(r, (8 - layers) * 2)
    for i = 0 to layers - 1
        if profiles[i] = 1 then resolutionSkip(r, 88)
        if levels[i] = 1 then resolutionSkip(r, 8)
    end for
    resolutionUe(r)
    chroma = resolutionUe(r)
    if chroma > 3 then return {}
    if chroma = 3 and resolutionRead(r, 1) = 1 then chroma = 0
    width = resolutionUe(r): height = resolutionUe(r)
    if resolutionRead(r, 1) = 1
        leftCrop = resolutionUe(r): rightCrop = resolutionUe(r)
        topCrop = resolutionUe(r): bottomCrop = resolutionUe(r)
        cropX = 1: cropY = 1
        if chroma = 1 or chroma = 2 then cropX = 2
        if chroma = 1 then cropY = 2
        width = width - cropX * (leftCrop + rightCrop)
        height = height - cropY * (topCrop + bottomCrop)
    end if
    if not r.ok then return {}
    return resolutionPair(width, height, "HEVC")
end function

function resolutionElementary(data as object, limit as integer) as object
    sync = -1
    for i = 0 to 187
        if i + 376 >= limit then exit for
        if data[i] = 71 and data[i + 188] = 71 and data[i + 376] = 71
            sync = i
            exit for
        end if
    end for
    if sync < 0 then return { bytes: data, transport: false }
    videoPid = -1
    result = []
    for packet = sync to limit - 188 step 188
        if data[packet] <> 71 then return { bytes: result, transport: true }
        ' Scrambled transport packets cannot provide clear picture headers.
        if (data[packet + 3] and 192) <> 0 then return { bytes: [], transport: true }
        pid = (data[packet + 1] and 31) * 256 + data[packet + 2]
        control = Int(data[packet + 3] / 16) and 3
        payload = packet + 4
        if control = 2 or control = 3 then payload = payload + 1 + data[packet + 4]
        if control = 1 or control = 3
            finish = packet + 188
            if payload + 9 <= finish and (data[packet + 1] and 64) <> 0
                if data[payload] = 0 and data[payload + 1] = 0 and data[payload + 2] = 1
                    if data[payload + 3] >= 224 and data[payload + 3] <= 239
                        if videoPid < 0 then videoPid = pid
                        payload = payload + 9 + data[payload + 8]
                    end if
                end if
            end if
            if pid = videoPid and payload < finish
                for i = payload to finish - 1
                    result.Push(data[i])
                    if result.Count() >= 65536 then return { bytes: result, transport: true }
                end for
            end if
        end if
    end for
    return { bytes: result, transport: true }
end function

function resolutionFromBytes(data as object, codecHint = "" as string, allowAnnex = false as boolean) as object
    limit = data.Count()
    if limit > 131072 then limit = 131072
    if limit < 8 then return {}
    stream = resolutionElementary(data, limit)
    bytes = stream.bytes
    if bytes.Count() < limit then limit = bytes.Count()
    if not stream.transport and not allowAnnex then return resolutionMp4Config(bytes, limit)
    hint = LCase(codecHint)
    unknown = (hint = "" or hint = "unknown")
    avc = (unknown or hint = "mpeg4_10b" or hint = "mpeg4_15" or hint = "h264" or hint = "avc")
    hevc = (unknown or hint.Left(4) = "hevc")
    mpeg2 = (unknown or hint = "mpeg2")
    for i = 0 to limit - 6
        if bytes[i] = 0 and bytes[i + 1] = 0 and bytes[i + 2] = 1
            start = i + 3
            finish = start + 4096
            if finish > limit then finish = limit
            for j = start + 1 to finish - 3
                if bytes[j] = 0 and bytes[j + 1] = 0 and bytes[j + 2] = 1
                    finish = j
                    exit for
                end if
            end for
            result = {}
            if avc and (bytes[start] and 31) = 7 and (bytes[start] and 128) = 0
                result = resolutionH264(bytes, start, finish)
            else if hevc and (bytes[start] and 128) = 0 and (Int(bytes[start] / 2) and 63) = 33 and (bytes[start + 1] and 7) <> 0
                result = resolutionHevc(bytes, start, finish)
            else if mpeg2 and bytes[start] = 179 and start + 3 < limit
                result = resolutionPair(bytes[start + 1] * 16 + Int(bytes[start + 2] / 16), (bytes[start + 2] and 15) * 256 + bytes[start + 3], "MPEG-2")
            end if
            if result.width <> invalid then return result
        end if
    end for
    return resolutionMp4Config(bytes, limit)
end function

function resolutionMp4Config(data as object, limit as integer) as object
    ' Initialization fragments carry length-prefixed SPS NALs in avcC/hvcC.
    for i = 4 to limit - 12
        boxSize = data[i - 4] * 16777216# + data[i - 3] * 65536 + data[i - 2] * 256 + data[i - 1]
        validBox = (boxSize >= 12 and boxSize <= limit - i + 4)
        if validBox and data[i] = 97 and data[i + 1] = 118 and data[i + 2] = 99 and data[i + 3] = 67 and data[i + 4] = 1
            if (data[i + 9] and 31) > 0
                length = data[i + 10] * 256 + data[i + 11]
                if length <= 4096 and i + 12 + length <= limit
                    result = resolutionH264(data, i + 12, i + 12 + length)
                    if result.width <> invalid then return result
                end if
            end if
        else if validBox and data[i] = 104 and data[i + 1] = 118 and data[i + 2] = 99 and data[i + 3] = 67 and data[i + 4] = 1
            p = i + 4
            if p + 23 <= limit
                arrays = data[p + 22]
                cursor = p + 23
                for a = 1 to arrays
                    if cursor + 3 > limit then exit for
                    kind = data[cursor] and 63
                    count = data[cursor + 1] * 256 + data[cursor + 2]
                    cursor = cursor + 3
                    for n = 1 to count
                        if cursor + 2 > limit then return {}
                        length = data[cursor] * 256 + data[cursor + 1]
                        cursor = cursor + 2
                        if length <= 0 or cursor + length > limit then return {}
                        if kind = 33 and length <= 4096
                            result = resolutionHevc(data, cursor, cursor + length)
                            if result.width <> invalid then return result
                        end if
                        cursor = cursor + length
                    end for
                end for
            end if
        end if
    end for
    return {}
end function
