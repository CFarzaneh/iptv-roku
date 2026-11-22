sub main()
    base = "https://provider.example/movie/user/pass/"
    movie = onDemandMovie({stream_id: 42, name: " A Movie ", container_extension: "MKV", releaseDate: "2024-02-01", plot: "Description"}, base, "Drama", "account")
    check(movie.name = "A Movie" and movie.year = "2024", "catalog metadata")
    check(movie.streamFormat = "mkv" and movie.url = base + "42.mkv" and movie.compatible, "use provider's supported container")
    check(isOnDemand(movie) and movie.resumeKey = "account:movie:42", "local resume is scoped by account and content kind")
    check(dashboardChannelId(movie) = "movie:42", "movie IDs do not collide with live IDs")
    check(not isOnDemand({providerStreamId: 42}) and isOnDemand({mediaKind: "episode"}), "existing live streams and future episodes")
    check(onDemandMovie({stream_id: "../1", name: "Bad ID", container_extension: "mp4"}, base, "", "") = invalid, "reject malformed stream identifiers")

    unknown = onDemandMovie({stream_id: "43", name: "Unsupported", container_extension: "avi"}, base, "Drama", "account")
    check(not unknown.compatible and unknown.url = "", "unsupported format cannot open a stream")
    check(onDemandFormat("m4v") = "mp4" and onDemandFormat("m3u8") = "hls", "movie format mapping")
    check(onDemandFileSize({}) = 0, "empty Stat during catalog transfer")
    check(onDemandFileSize({size: 188}) = 188, "catalog file size available")

    check(onDemandTime(3661) = "1:01:01" and onDemandTime(59) = "0:59", "movie timeline display")
    m.video = {state: "playing", duration: 100, control: "play"}
    m.vodPosition = 85
    check(handleOnDemandKey("fastforward", true), "forward button is handled")
    check(m.video.seek = 99 and m.video.autoplayAfterSeek, "forward skips without overshooting movie duration")
    m.video.state = "paused"
    m.vodPosition = 5
    check(handleOnDemandKey("rewind", true), "rewind button is handled")
    check(m.video.seek = 0 and not m.video.autoplayAfterSeek, "rewind clamps at start and preserves pause")
    check(handleOnDemandKey("play", true) and m.video.control = "resume", "resume a paused movie")
    checkMovieSearch()
    print "On-demand checks passed"
end sub

sub checkMovieSearch()
    m.top = {cancelRequested: false}
    m.requests = []
    categories = [
        {providerId: "10", title: "Drama"},
        {providerId: "20", title: "Classics"},
        {providerId: "30", title: "Unavailable"},
        {providerId: "20", title: "Duplicate category"}
    ]
    catalog = {
        streamsUrl: "https://provider.example/player_api.php?action=get_vod_streams",
        streamBase: "https://provider.example/movie/user/pass/",
        accountScope: "account",
        query: "night"
    }
    result = {channels: [], totalMatches: 0}
    searchMovieCategories(result, catalog, categories, fixtureMovieFetch)
    check(m.requests.Count() = 3, "each distinct category is requested once")
    check(result.totalMatches = 2 and result.channels.Count() = 2, "merge matches without duplicate stream IDs")
    check(result.channels[0].group = "Drama" and result.channels[1].group = "Classics", "retain matching category")
    check(result.incomplete and result.error = invalid, "keep matches and flag an unavailable category")

    m.requests = []
    result = {channels: [], totalMatches: 0}
    searchMovieCategories(result, catalog, [categories[2]], fixtureMovieFetch)
    check(result.error = "Movie catalog is too large", "all categories failing is a search error")

    m.top.cancelRequested = true
    m.requests = []
    searchMovieCategories({channels: [], totalMatches: 0}, catalog, categories, fixtureMovieFetch)
    check(m.requests.Count() = 0, "cancelled search starts no more category requests")
end sub

function fixtureMovieFetch(url as string, timeout as integer) as object
    m.requests.Push(url)
    check(url.Instr("&category_id=") >= 0, "search must never fetch the full catalog when categories are available")
    check(timeout > 0 and timeout <= 10000, "category requests have bounded timeouts")
    if url.Right(2) = "10"
        return {rows: [{stream_id: 42, name: "Late Night", container_extension: "mp4"}, {stream_id: 43, name: "Daybreak", container_extension: "mp4"}]}
    else if url.Right(2) = "20"
        return {rows: [{stream_id: "42", name: "Late Night", container_extension: "mp4"}, {stream_id: 54, name: "Night Train", container_extension: "mkv"}]}
    end if
    return {error: "Movie catalog is too large", httpCode: 200}
end function

sub showOverlay()
end sub

sub hideOverlay()
end sub

sub exitPlayer()
end sub

sub check(condition as boolean, label as string)
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
