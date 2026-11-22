' Each device stores a bounded list of IDs and timestamps in the Roku registry.
' No titles, provider URLs, or credentials are written here.
function loadOnDemandPositions(section as object) as object
    data = section.Read("positions")
    if data = "" then return []
    entries = ParseJson(data)
    if GetInterface(entries, "ifArray") = invalid then return []
    return entries
end function

function readOnDemandPosition(key as string) as integer
    if key = "" then return 0
    section = CreateObject("roRegistrySection", "onDemand")
    for each item in loadOnDemandPositions(section)
        if GetInterface(item, "ifAssociativeArray") <> invalid
            if item.key = key and GetInterface(item.position, "ifInt") <> invalid
                if item.position >= 10 then return item.position
            end if
        end if
    end for
    return 0
end function

function writeOnDemandPosition(key as string, position as integer) as boolean
    if key = "" then return false
    section = CreateObject("roRegistrySection", "onDemand")
    entries = loadOnDemandPositions(section)
    updated = []
    if position >= 10 then updated.Push({key: key, position: position})
    for each item in entries
        if updated.Count() >= 60 then exit for
        if GetInterface(item, "ifAssociativeArray") <> invalid
            if item.key <> key then updated.Push(item)
        end if
    end for
    if not section.Write("positions", FormatJson(updated)) then return false
    return section.Flush()
end function
