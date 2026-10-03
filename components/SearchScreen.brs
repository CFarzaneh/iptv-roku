' SearchScreen: case-insensitive local or full-provider search

sub init()
    m.searchButton = m.top.findNode("searchButton")
    m.titleLabel = m.top.findNode("titleLabel")
    m.headerLabel = m.top.findNode("headerLabel")
    m.channelGrid = m.top.findNode("channelGrid")
    m.statusLabel = m.top.findNode("statusLabel")
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.toastTimer = m.top.findNode("toastTimer")

    m.channelGrid.observeField("itemSelected", "onChannelSelected")
    m.searchButton.observeField("itemSelected", "onSearchButtonSelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("visible", "onVisibleChange")

    theme = getTheme()
    if theme <> invalid
        m.titleLabel.color = theme.colorText
        m.headerLabel.color = theme.colorText
        m.statusLabel.color = theme.colorTextDim
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.searchButton.color = theme.colorText
        m.searchButton.focusedColor = theme.colorOnAccent
        m.channelGrid.itemSpacing = [0, 6]
    end if

    m.allChannels = []
    m.currentChannels = []
    m.searchDraft = ""
    m.searchDialog = invalid
    m.providerTask = invalid
    buildSearchButton()
end sub

sub onVisibleChange()
    if not m.top.visible then return
    if hasSearchResults()
        m.channelGrid.setFocus(true)
    else
        m.searchButton.setFocus(true)
    end if
end sub

sub buildSearchButton()
    content = CreateObject("roSGNode", "ContentNode")
    m.searchButtonItem = content.createChild("ContentNode")
    m.searchButton.content = content
    setSearchButtonText("Search channels")
end sub

sub setSearchButtonText(text as string)
    if m.searchButtonItem <> invalid then m.searchButtonItem.title = text
end sub

function hasSearchResults() as boolean
    if m.currentChannels = invalid or m.currentChannels.Count() = 0 then return false
    if m.channelGrid.content = invalid then return false
    return m.channelGrid.content.getChildCount() > 0
end function

sub onChannelsChange()
    m.allChannels = m.top.channels
    if m.allChannels = invalid then m.allChannels = []
end sub

sub onSearchButtonSelected()
    if m.searchDialog <> invalid then return
    if m.providerTask <> invalid
        showToast("The current search is still running")
        return
    end if
    dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
    dialog.title = "Search live channels"
    dialog.buttons = ["Search", "Cancel"]
    dialog.text = m.searchDraft
    dialog.textEditBox.maxTextLength = 120
    dialog.observeField("buttonSelected", "onSearchDialogButton")
    dialog.observeField("wasClosed", "onSearchDialogClosed")
    scene = m.top.getScene()
    if scene = invalid
        showToast("Could not open the keyboard")
        return
    end if
    m.searchDialog = dialog
    scene.dialog = dialog
end sub

sub onSearchDialogButton(event as object)
    if m.searchDialog = invalid then return
    if event.getData() <> 0
        m.searchDialog.close = true
        return
    end if

    query = m.searchDialog.text.Trim()
    if query.Len() < 2
        m.searchDialog.title = "Enter at least 2 characters"
        return
    end if
    m.searchDraft = query
    m.searchDialog.close = true
    startSearch(query)
end sub

sub onSearchDialogClosed()
    if m.searchDialog = invalid then return
    if m.searchDialog.text <> invalid then m.searchDraft = m.searchDialog.text.Trim()
    m.searchDialog = invalid
    if m.top.visible
        if hasSearchResults()
            m.channelGrid.setFocus(true)
        else
            m.searchButton.setFocus(true)
        end if
    end if
end sub

sub startSearch(query as string)
    setSearchButtonText("Search: " + query)
    m.channelGrid.content = CreateObject("roSGNode", "ContentNode")
    m.currentChannels = []
    m.headerLabel.text = ""
    m.statusLabel.visible = true

    if m.top.providerMode = true and m.top.accountConfig <> invalid
        m.statusLabel.text = "Searching all live channels…"
        m.providerTask = CreateObject("roSGNode", "XtreamTask")
        m.providerTask.accountConfig = m.top.accountConfig
        m.providerTask.searchQuery = query
        m.providerTask.playlistUrl = "xtream://configured-account"
        m.providerTask.observeField("status", "onProviderSearchStatus")
        m.providerTask.control = "RUN"
    else
        performLocalSearch(query)
    end if
end sub

sub onProviderSearchStatus()
    if m.providerTask = invalid then return
    status = m.providerTask.status
    if status <> "ok" and status <> "cache" and status <> "error" then return

    if status = "ok" or status = "cache"
        result = m.providerTask.result
        if result <> invalid and result.channels <> invalid
            totalMatches = result.channels.Count()
            if result.totalMatches <> invalid then totalMatches = result.totalMatches
            renderResults(m.searchDraft, result.channels, totalMatches)
        else
            showSearchError("Provider returned no search results")
        end if
    else
        reason = m.providerTask.error
        if reason = invalid or reason = "" then reason = "Search request failed"
        showSearchError(reason)
    end if
    m.providerTask = invalid
end sub

sub performLocalSearch(query as string)
    qLower = LCase(query)
    matches = []
    for each ch in m.allChannels
        nameLower = LCase(ch.name)
        tvgLower = ""
        if ch.tvgName <> invalid then tvgLower = LCase(ch.tvgName)
        if Instr(1, nameLower, qLower) > 0 or (tvgLower <> "" and Instr(1, tvgLower, qLower) > 0)
            matches.Push(ch)
        end if
    end for
    renderResults(query, matches, matches.Count())
end sub

sub renderResults(query as string, channels as object, totalMatches as integer)
    favs = LoadFavorites()
    gridContent = CreateObject("roSGNode", "ContentNode")
    m.currentChannels = []
    for each ch in channels
        isFav = false
        if favs <> invalid
            for each f in favs
                if f = ch.name
                    isFav = true
                    exit for
                end if
            end for
        end if
        addChannel(gridContent, ch, isFav)
        m.currentChannels.Push(ch)
    end for

    m.channelGrid.content = gridContent
    setSearchButtonText("Search: " + query)
    if totalMatches > 0
        shown = m.currentChannels.Count()
        if totalMatches > shown
            m.headerLabel.text = "Found: " + totalMatches.ToStr() + " (showing first " + shown.ToStr() + ")"
        else
            m.headerLabel.text = "Found: " + totalMatches.ToStr()
        end if
        m.statusLabel.visible = false
        m.channelGrid.jumpToItem = 0
        m.channelGrid.setFocus(true)
    else
        m.headerLabel.text = "Found: 0"
        m.statusLabel.visible = true
        m.statusLabel.text = "Nothing found"
        m.searchButton.setFocus(true)
    end if
end sub

sub showSearchError(reason as string)
    m.headerLabel.text = "Search unavailable"
    m.statusLabel.visible = true
    m.statusLabel.text = reason
    m.searchButton.setFocus(true)
end sub

sub addChannel(parent as object, ch as object, isFav as boolean)
    item = parent.createChild("ChannelContent")
    item.name = ch.name
    item.title = ch.name
    item.url = ch.url
    item.group = ch.group
    item.logo = ch.logo
    item.HDPosterUrl = ch.logo
    item.compatible = ch.compatible
    item.favorite = isFav
    item.wide = true
end sub

sub onChannelSelected()
    idx = m.channelGrid.itemSelected
    if m.channelGrid.content = invalid return
    item = m.channelGrid.content.getChild(idx)
    if item = invalid return
    if item.compatible
        m.top.playRequest = { channels: m.currentChannels, index: idx }
    else
        showToast("Stream not supported")
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back"
        if m.channelGrid.hasFocus()
            m.searchButton.setFocus(true)
        else
            m.top.exitRequested = not m.top.exitRequested
        end if
        return true
    else if (key = "down" or key = "right") and m.searchButton.hasFocus()
        if hasSearchResults() then m.channelGrid.setFocus(true)
        return true
    else if key = "up" and m.channelGrid.hasFocus() and m.channelGrid.itemFocused = 0
        m.searchButton.setFocus(true)
        return true
    else if key = "options" and m.channelGrid.hasFocus()
        idx = m.channelGrid.itemFocused
        if m.channelGrid.content <> invalid
            item = m.channelGrid.content.getChild(idx)
            if item <> invalid
                isFav = ToggleFavorite(item.name)
                item.favorite = isFav
                if isFav
                    showToast("Added to favorites")
                else
                    showToast("Removed from favorites")
                end if
            end if
        end if
        return true
    end if
    return false
end function

sub showToast(msg as string)
    m.toastLabel.text = msg
    m.toastBg.visible = true
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toastBg.visible = false
end sub
