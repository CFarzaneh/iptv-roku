' ChannelsScreen: rail and grid

sub init()
    m.categoryList = m.top.findNode("categoryList")
    m.channelGrid = m.top.findNode("channelGrid")
    m.headerLabel = m.top.findNode("headerLabel")
    m.emptyLabel = m.top.findNode("emptyLabel")
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.toastTimer = m.top.findNode("toastTimer")
    
    m.categoryList.observeField("itemFocused", "onCategoryFocused")
    m.categoryList.observeField("itemSelected", "onCategorySelected")
    m.toastTimer.observeField("fire", "hideToast")
    m.top.observeField("restoreFocus", "onRestoreFocus")
    m.top.observeField("noticeCommand", "onNotice")
    
    theme = getTheme()
    if theme <> invalid
        m.categoryList.color = theme.colorTextDim
        ' On-accent, because the chip underneath is now brand green (see the
        ' focusBitmapBlendColor on categoryList). This line used to set colorText, which
        ' overwrote the XML value and left off-white on the stock grey chip at 1.29:1.
        m.categoryList.focusedColor = theme.colorOnAccent
        m.headerLabel.color = theme.colorText
        m.emptyLabel.color = theme.colorTextDim
        m.toastBg.color = theme.colorSurface
        m.toastLabel.color = theme.colorText
        m.channelGrid.itemSpacing = [0, 6]
    end if
    
    ' Position memory map: categoryIndex -> focused channel index
    m.gridFocusMemory = {} 
    m.currentChannels = []
    m.gridCache = {}
    m.channelsCache = {}
    m.knownChannels = []
    m.knownChannelUrls = {}
    m.providerTask = invalid
    m.providerLoading = false
    m.providerCategoryIndex = -1
    m.favSet = {}
    m.pendingIdx = -1
    m.currentCategoryIdx = -1
    m.gridDebounceTimer = m.top.findNode("gridDebounceTimer")
    m.gridDebounceTimer.observeField("fire", "onGridDebounceFire")
    
    m.okTimer = m.top.findNode("okTimer")
    m.okTimer.observeField("fire", "onOkLongPress")
    m.okLongFired = false
end sub

sub rebuildFavSet()
    m.favSet = {}
    favs = LoadFavorites()
    if favs <> invalid
        for each f in favs
            m.favSet[f] = true
        end for
    end if
end sub

sub clearGridCache()
    m.gridCache = {}
    m.channelsCache = {}
end sub

' Refresh favorite state without clearing the whole cache.
' dropRecent=true also invalidates Recent (after the player).
sub refreshFavState(dropRecent as boolean)
    rebuildFavSet()
    keysToDrop = ["1"]
    if dropRecent then keysToDrop.Push("2")
    for each k in keysToDrop
        if m.gridCache.DoesExist(k) then m.gridCache.Delete(k)
        if m.channelsCache.DoesExist(k) then m.channelsCache.Delete(k)
    end for
    for each key in m.gridCache
        content = m.gridCache[key]
        if content <> invalid
            for i = 0 to content.getChildCount() - 1
                child = content.getChild(i)
                child.favorite = (m.favSet[child.name] <> invalid)
            end for
        end if
    end for
end sub

function headerForCategory(idx as integer) as string
    if idx = 1 then return "CHANNELS — Favorites"
    if idx = 2 then return "CHANNELS — Recent"
    res = m.top.playlistResult
    catIndex = idx - 3
    if res <> invalid and res.categories <> invalid and catIndex >= 0 and catIndex < res.categories.Count()
        cat = res.categories[catIndex]
        if cat.count > 0 then return "CHANNELS — " + cat.title + " (" + cat.count.ToStr() + ")"
        return "CHANNELS — " + cat.title
    end if
    return "CHANNELS"
end function

function emptyTextForCategory(idx as integer) as string
    if idx = 1 then return "No favorites yet"
    if idx = 2 then return "Nothing watched yet"
    return "Nothing found"
end function

function buildGridForCategory(idx as integer) as object
    res = m.top.playlistResult
    gridContent = CreateObject("roSGNode", "ContentNode")
    channels = []
    if res = invalid then return { content: gridContent, channels: channels }

    availableChannels = res.channels
    if res.providerMode = true then availableChannels = m.knownChannels

    if idx = 1 ' Favorites
        if availableChannels <> invalid
            for each ch in availableChannels
                if m.favSet[ch.name] <> invalid
                    addChannel(gridContent, ch, true)
                    channels.Push(ch)
                end if
            end for
        end if
    else if idx = 2 ' Recents
        recents = LoadRecents()
        if recents <> invalid and availableChannels <> invalid
            for each r in recents
                for each ch in availableChannels
                    if ch.name = r
                        addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid))
                        channels.Push(ch)
                        exit for
                    end if
                end for
            end for
        end if
    else ' Regular category ("All" or others)
        catIndex = idx - 3
        if catIndex >= 0 and res.categories <> invalid and catIndex < res.categories.Count()
            cat = res.categories[catIndex]
            if availableChannels <> invalid
                for each ch in availableChannels
                    if cat.title = "All" or ch.group = cat.title
                        addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid))
                        channels.Push(ch)
                    end if
                end for
            end if
        end if
    end if
    return { content: gridContent, channels: channels }
end function

sub onPlaylistChange()
    res = m.top.playlistResult
    if res = invalid return
    
    m.knownChannels = []
    m.knownChannelUrls = {}
    m.providerTask = invalid
    m.providerLoading = false
    m.providerCategoryIndex = -1
    if res.channels <> invalid and res.channels.Count() > 0
        addKnownChannels(res.channels)
        ' Before migration and the purge, so everything downstream sees the restored
        ' data on the run that seeds it.
        RestoreStoreIfEmpty()
        MigrateStoreToNames(res.channels)
        PurgeAdultFromRecents(res.channels)
    end if
    ' Viewing history stays in the registry; do not print it to the console.
    
    buildCategories()
    clearGridCache()
    rebuildFavSet()
    
    m.categoryList.setFocus(true)
    ' Default to "Favorites" which is index 1
    if m.categoryList.content <> invalid and m.categoryList.content.getChildCount() > 1
        m.categoryList.jumpToItem = 1
    end if
end sub

sub buildCategories()
    res = m.top.playlistResult
    if res = invalid return
    
    favs = LoadFavorites()
    recents = LoadRecents()
    
    favCount = 0
    if favs <> invalid then favCount = favs.Count()
    recCount = 0
    if recents <> invalid then recCount = recents.Count()
    
    content = CreateObject("roSGNode", "ContentNode")
    
    addCategory(content, "Search")
    addCategory(content, "★ Favorites (" + favCount.ToStr() + ")")
    addCategory(content, "Recent (" + recCount.ToStr() + ")")
    
    if res.categories <> invalid
        for each cat in res.categories
            title = cat.title
            if cat.count > 0 then title = title + " (" + cat.count.ToStr() + ")"
            addCategory(content, title)
        end for
    end if
    
    addCategory(content, "Settings")
    
    m.categoryList.content = content
end sub

sub addCategory(parent as object, title as string)
    item = parent.createChild("ContentNode")
    item.title = title
end sub

sub updateCategoryCounts()
    favs = LoadFavorites()
    recents = LoadRecents()
    
    favCount = 0
    if favs <> invalid then favCount = favs.Count()
    recCount = 0
    if recents <> invalid then recCount = recents.Count()
    
    if m.categoryList.content <> invalid
        favNode = m.categoryList.content.getChild(1)
        if favNode <> invalid then favNode.title = "★ Favorites (" + favCount.ToStr() + ")"
        
        recNode = m.categoryList.content.getChild(2)
        if recNode <> invalid then recNode.title = "Recent (" + recCount.ToStr() + ")"
    end if
end sub

sub onCategoryFocused()
    m.pendingIdx = m.categoryList.itemFocused
    m.gridDebounceTimer.control = "stop"
    m.gridDebounceTimer.control = "start"
end sub

sub onGridDebounceFire()
    if m.pendingIdx >= 0
        updateGridForCategory(m.pendingIdx)
        m.pendingIdx = -1
    end if
end sub

sub flushPendingGrid()
    m.gridDebounceTimer.control = "stop"
    if m.pendingIdx >= 0
        updateGridForCategory(m.pendingIdx)
        m.pendingIdx = -1
    end if
end sub

sub onCategorySelected()
    idx = m.categoryList.itemSelected
    if idx = 0
        m.top.openSearch = not m.top.openSearch
    else if m.categoryList.content <> invalid and idx = m.categoryList.content.getChildCount() - 1
        m.top.openSettings = not m.top.openSettings
    else
        res = m.top.playlistResult
        catIndex = idx - 3
        if res <> invalid and res.providerMode = true and res.categories <> invalid
            if catIndex >= 0 and catIndex < res.categories.Count()
                key = idx.ToStr()
                if m.gridCache.DoesExist(key)
                    updateGridForCategory(idx)
                    if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
                        m.channelGrid.setFocus(true)
                    end if
                else
                    loadProviderCategory(idx, res.categories[catIndex])
                end if
            end if
        end if
    end if
end sub

sub updateGridForCategory(idx as integer)
    m.currentCategoryIdx = idx
    if m.categoryList.content = invalid then return
    lastIdx = m.categoryList.content.getChildCount() - 1

    ' Search / Settings — empty grid (cheap, not cached)
    if idx = 0 or idx = lastIdx
        m.channelGrid.content = CreateObject("roSGNode", "ContentNode")
        m.currentChannels = []
        m.emptyLabel.visible = true
        m.emptyLabel.text = "Select to open"
        m.headerLabel.text = "CHANNELS — " + m.categoryList.content.getChild(idx).title
        return
    end if

    res = m.top.playlistResult
    if res <> invalid and res.providerMode = true and idx >= 3
        key = idx.ToStr()
        if not m.gridCache.DoesExist(key)
            m.channelGrid.content = CreateObject("roSGNode", "ContentNode")
            m.currentChannels = []
            m.emptyLabel.visible = true
            if m.providerLoading and m.providerCategoryIndex = idx
                m.emptyLabel.text = "Loading this category…"
            else
                m.emptyLabel.text = "Press OK to load this category"
            end if
            m.headerLabel.text = headerForCategory(idx)
            return
        end if
    end if

    key = idx.ToStr()
    if not m.gridCache.DoesExist(key)
        built = buildGridForCategory(idx)
        m.gridCache[key] = built.content
        m.channelsCache[key] = built.channels
    end if

    m.channelGrid.content = m.gridCache[key]
    m.currentChannels = m.channelsCache[key]
    m.headerLabel.text = headerForCategory(idx)

    if m.currentChannels.Count() = 0
        m.emptyLabel.visible = true
        m.emptyLabel.text = emptyTextForCategory(idx)
    else
        m.emptyLabel.visible = false
        if m.gridFocusMemory.DoesExist(key)
            m.channelGrid.jumpToItem = m.gridFocusMemory[key]
        else
            m.channelGrid.jumpToItem = 0
        end if
    end if
end sub

sub loadProviderCategory(idx as integer, cat as object)
    if m.providerLoading
        showToast("Another category is still loading")
        return
    end if
    if cat = invalid or cat.providerId = invalid or m.top.accountConfig = invalid
        showToast("Provider account is unavailable")
        return
    end if

    m.providerLoading = true
    m.providerCategoryIndex = idx
    m.currentCategoryIdx = idx
    m.channelGrid.content = CreateObject("roSGNode", "ContentNode")
    m.currentChannels = []
    m.headerLabel.text = headerForCategory(idx)
    m.emptyLabel.visible = true
    m.emptyLabel.text = "Loading " + cat.title + "…"

    m.providerTask = CreateObject("roSGNode", "XtreamTask")
    m.providerTask.accountConfig = m.top.accountConfig
    m.providerTask.categoryId = cat.providerId
    m.providerTask.categoryName = cat.title
    m.providerTask.playlistUrl = "xtream://configured-account"
    m.providerTask.observeField("status", "onProviderCategoryStatus")
    m.providerTask.control = "RUN"
end sub

sub onProviderCategoryStatus()
    if m.providerTask = invalid then return
    status = m.providerTask.status
    if status <> "ok" and status <> "cache" and status <> "error" then return

    idx = m.providerCategoryIndex
    if status = "ok" or status = "cache"
        result = m.providerTask.result
        if result <> invalid and result.channels <> invalid
            gridContent = CreateObject("roSGNode", "ContentNode")
            channels = []
            for each ch in result.channels
                addChannel(gridContent, ch, (m.favSet[ch.name] <> invalid))
                channels.Push(ch)
            end for
            key = idx.ToStr()
            m.gridCache[key] = gridContent
            m.channelsCache[key] = channels
            addKnownChannels(channels)

            res = m.top.playlistResult
            catIndex = idx - 3
            if res <> invalid and res.categories <> invalid and catIndex >= 0 and catIndex < res.categories.Count()
                res.categories[catIndex].count = channels.Count()
                node = m.categoryList.content.getChild(idx)
                if node <> invalid
                    node.title = res.categories[catIndex].title + " (" + channels.Count().ToStr() + ")"
                end if
            end if
            m.top.catalogUpdate = { channels: m.knownChannels, newChannels: channels }
        end if
    else
        reason = m.providerTask.error
        if reason = invalid or reason = "" then reason = "Could not load this category"
        showToast(reason)
    end if

    m.providerLoading = false
    m.providerCategoryIndex = -1
    m.providerTask = invalid
    if status = "ok" or status = "cache"
        updateGridForCategory(idx)
        if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
            m.channelGrid.setFocus(true)
        end if
    else
        m.emptyLabel.visible = true
        m.emptyLabel.text = "Could not load. Press OK to retry"
    end if
end sub

sub addKnownChannels(channels as object)
    if channels = invalid then return
    for each ch in channels
        if ch.url <> invalid and not m.knownChannelUrls.DoesExist(ch.url)
            m.knownChannelUrls[ch.url] = true
            m.knownChannels.Push(ch)
        end if
    end for
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
end sub

sub playFocusedChannel()
    if m.channelGrid.content = invalid then return
    idx = m.channelGrid.itemFocused
    item = m.channelGrid.content.getChild(idx)
    if item = invalid then return

    if item.compatible
        ' remember where we were so Back from the player returns to this channel
        m.gridFocusMemory[m.currentCategoryIdx.ToStr()] = idx
        m.top.playRequest = { channels: m.currentChannels, index: idx }
    else
        showToast("Stream not supported")
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    handled = false

    ' Long OK on a card: short = play, long = favorite (add/remove by category)
    if key = "OK" and m.channelGrid.hasFocus()
        if press
            m.okLongFired = false
            m.okTimer.control = "stop"
            m.okTimer.control = "start"
        else
            m.okTimer.control = "stop"
            if not m.okLongFired then playFocusedChannel()
        end if
        return true
    end if

    if press
        if key = "right"
            if m.categoryList.hasFocus()
                flushPendingGrid()
                if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
                    m.channelGrid.setFocus(true)
                end if
                handled = true
            end if
        else if key = "left"
            if m.channelGrid.hasFocus()
                idx = m.channelGrid.itemFocused
                catIdx = m.currentCategoryIdx
                m.gridFocusMemory[catIdx.ToStr()] = idx
                m.categoryList.setFocus(true)
                handled = true
            end if
        else if key = "options"
            if m.channelGrid.hasFocus()
                idx = m.channelGrid.itemFocused
                if m.channelGrid.content <> invalid
                    item = m.channelGrid.content.getChild(idx)
                    if item <> invalid
                        isFav = ToggleFavorite(item.name)
                        item.favorite = isFav
                        refreshFavState(false)
                        catIdx = m.currentCategoryIdx
                        if catIdx = 1 and not isFav
                            updateGridForCategory(catIdx)
                            m.channelGrid.setFocus(true)
                        end if
                        updateCategoryCounts()
                    end if
                end if
                handled = true
            end if
        end if
    end if
    return handled
end function

sub onNotice()
    showToast(m.top.notice)
end sub

sub showToast(msg as string)
    m.toastLabel.text = msg
    m.toastBg.visible = true
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toastBg.visible = false
end sub

sub onRestoreFocus()
    refreshFavState(true)
    updateCategoryCounts()
    curIdx = m.currentCategoryIdx
    if curIdx < 0 then curIdx = m.categoryList.itemFocused
    updateGridForCategory(curIdx)
    if m.channelGrid.content <> invalid and m.channelGrid.content.getChildCount() > 0
        m.channelGrid.setFocus(true)
    else
        m.categoryList.setFocus(true)
    end if
end sub

sub onOkLongPress()
    m.okLongFired = true
    if not m.channelGrid.hasFocus() then return
    if m.channelGrid.content = invalid then return
    idx = m.channelGrid.itemFocused
    item = m.channelGrid.content.getChild(idx)
    if item = invalid then return

    catIdx = m.currentCategoryIdx
    if catIdx = 1
        ' Favorites category — remove from favorites
        if IsFavorite(item.name)
            ToggleFavorite(item.name)
            item.favorite = false
            showToast("Removed from favorites")
            refreshFavState(false)
            updateGridForCategory(1)
            m.channelGrid.setFocus(true)
            updateCategoryCounts()
        end if
    else
        ' Other categories — add to favorites
        if IsFavorite(item.name)
            showToast("Already in favorites")
        else
            ToggleFavorite(item.name)
            item.favorite = true
            showToast("Added to favorites")
            refreshFavState(false)
            updateCategoryCounts()
        end if
    end if
end sub
