sub main()
    m.checks = 0
    fixtures = ParseJson(ReadAsciiFile("pkg:/fixtures/resolution.json"))
    for each fixture in fixtures
        data = []
        digits = "0123456789abcdef"
        for i = 0 to fixture.hex.Len() - 1 step 2
            data.Push(digits.Instr(fixture.hex.Mid(i, 1)) * 16 + digits.Instr(fixture.hex.Mid(i + 1, 1)))
        end for
        allowAnnex = (fixture.name.Instr("annex") >= 0 or fixture.name = "mpeg2-sequence")
        result = resolutionFromBytes(data, "", allowAnnex)
        if fixture.width > 0
            check(result.width = fixture.width and result.height = fixture.height, fixture.name)
            if allowAnnex then check(resolutionFromBytes(data).width = invalid, "unwrapped input rejected: " + fixture.name)
        else
            check(result.width = invalid and result.height = invalid, fixture.name)
        end if
    end for
    check(resolutionSafeSegment("https://example.com/hls/session/segment.ts?token=example", "https://example.com/channel.m3u8"), "active segment accepted")
    check(resolutionSafeSegment("https://example.com/hls/init.mp4", "https://example.com/channel.m3u8"), "init fragment accepted")
    check(not resolutionSafeSegment("http://example.com/live/u/p/1.ts", "http://example.com/channel.m3u8"), "never open a direct live transport")
    check(not resolutionSafeSegment("http://example.com/chunk.ts", "http://example.com/chunk.ts"), "never reopen channel entry")
    check(not resolutionSafeSegment("file:///tmp/secret.ts", ""), "local files not probed")
    check(not resolutionSafeSegment("https://example.com/channel.m3u8", ""), "channel playlists not probed")
    print "Resolution parser checks passed: "; m.checks
end sub

sub check(condition as boolean, label as string)
    m.checks = m.checks + 1
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
