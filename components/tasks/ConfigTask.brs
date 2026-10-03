' Task for reading and parsing the configuration file
sub init()
    m.top.functionName = "loadConfig"
end sub

sub loadConfig()
    configStr = ReadAsciiFile("pkg:/config.json")
    if configStr = ""
        m.top.error = "File not found or empty"
        return
    end if
    
    configObj = ParseJson(configStr)
    if configObj = invalid
        m.top.error = "Invalid JSON"
        return
    end if
    
    sec = CreateObject("roRegistrySection", "settings")
    if sec.Exists("dashboardProvider")
        saved = ParseJson(sec.Read("dashboardProvider"))
        if saved <> invalid and saved.server <> invalid
            configObj.importRevision = ""
            configObj.Delete("xtream")
            configObj.playlistUrl = saved.server
            configObj.extraPlaylists = []
            if saved.providerType = "xtream"
                configObj.xtream = { server: saved.server, username: saved.username, password: saved.password }
                configObj.playlistUrl = "xtream://primary"
            end if
            sec.Write("playlistUrl", configObj.playlistUrl)
            sec.Flush()
        end if
    end if
    m.top.config = configObj
end sub
