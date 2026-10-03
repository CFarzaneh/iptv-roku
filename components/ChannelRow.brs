' Dense channel guide row: logo, full channel name, and now/next EPG.

sub init()
    m.background = m.top.findNode("background")
    m.fallbackBg = m.top.findNode("fallbackBg")
    m.fallbackLabel = m.top.findNode("fallbackLabel")
    m.logo = m.top.findNode("logo")
    m.nameLabel = m.top.findNode("nameLabel")
    m.nowLabel = m.top.findNode("nowLabel")
    m.nextLabel = m.top.findNode("nextLabel")
    m.favStar = m.top.findNode("favStar")
    m.errorBadge = m.top.findNode("errorBadge")
    m.columnLine = m.top.findNode("columnLine")

    theme = getTheme()
    if theme <> invalid
        m.background.color = theme.colorSurface
        m.nameLabel.color = theme.colorText
        m.nowLabel.color = theme.colorText
        m.nextLabel.color = theme.colorTextDim
        m.columnLine.color = theme.colorLine
        m.favStar.color = theme.colorFocusBright
        m.errorBadge.color = theme.colorError
    end if

    ' MarkupList may assign itemContent before its item script finishes init on some
    ' Roku models. Observe it here and also paint an already-assigned value.
    m.top.observeField("itemContent", "onContentChange")
    if m.global <> invalid
        if m.global.epgReady <> invalid then m.global.observeField("epgReady", "onEpgReady")
        if m.global.nowSec <> invalid then m.global.observeField("nowSec", "onClockChanged")
    end if
    if m.top.itemContent <> invalid then onContentChange()
end sub

sub applyRowLayout(wide as boolean)
    if m.rowWide <> invalid and m.rowWide = wide then return
    m.rowWide = wide

    if wide
        m.background.width = 1728
        m.nameLabel.width = 760
        m.columnLine.translation = [846, 10]
        m.nowLabel.translation = [866, 4]
        m.nowLabel.width = 790
        m.nextLabel.translation = [866, 34]
        m.nextLabel.width = 790
        m.favStar.translation = [1686, 15]
        m.errorBadge.translation = [1706, 46]
    else
        m.background.width = 1356
        m.nameLabel.width = 602
        m.columnLine.translation = [686, 10]
        m.nowLabel.translation = [704, 4]
        m.nowLabel.width = 610
        m.nextLabel.translation = [704, 34]
        m.nextLabel.width = 610
        m.favStar.translation = [1320, 15]
        m.errorBadge.translation = [1334, 46]
    end if
end sub

sub onContentChange()
    content = m.top.itemContent
    if content = invalid then return

    applyRowLayout(content.wide = true)

    name = content.title
    if name = invalid or name = "" then name = content.name
    logoUrl = content.HDPosterUrl
    if logoUrl = invalid or logoUrl = "" then logoUrl = content.logo

    m.nameLabel.text = name
    m.fallbackBg.visible = true
    m.fallbackBg.color = getColorFromHash(name)
    m.fallbackLabel.text = getInitials(name)
    if logoUrl <> invalid and logoUrl <> ""
        m.logo.uri = logoUrl
        m.logo.visible = true
    else
        m.logo.visible = false
    end if
    m.favStar.visible = (content.favorite = true)
    m.errorBadge.visible = (content.compatible = false)
    updateGuide()
end sub

sub onEpgReady()
    updateGuide()
end sub

sub onClockChanged()
    updateGuide()
end sub

sub updateGuide()
    if m.top.itemContent = invalid then return
    name = m.top.itemContent.title
    if name = invalid or name = "" then name = m.top.itemContent.name
    epgMap = invalid
    nowSec = invalid
    if m.global <> invalid
        epgMap = m.global.epg
        nowSec = m.global.nowSec
    end if
    info = EpgFind(epgMap, name, nowSec)
    if info.now <> invalid
        m.nowLabel.text = EpgFmtHM(info.now.s) + "–" + EpgFmtHM(info.now.e) + "  " + info.now.t
    else
        m.nowLabel.text = "No current programme information"
    end if
    if info.next <> invalid
        m.nextLabel.text = "Next " + EpgFmtHM(info.next.s) + "  " + info.next.t
    else
        m.nextLabel.text = ""
    end if
end sub

function getInitials(name as string) as string
    if name = invalid or name = "" then return ""
    parts = name.Split(" ")
    if parts.Count() = 0 then return ""
    if parts.Count() > 1
        return Mid(parts[0], 1, 1) + Mid(parts[1], 1, 1)
    end if
    return Mid(parts[0], 1, 2)
end function

function getColorFromHash(name as string) as string
    if name = invalid or name = "" then return "0x333333FF"
    hash = 0
    for i = 1 to Len(name)
        hash = hash + Asc(Mid(name, i, 1))
    end for
    colors = ["0x2F6E4EFF", "0x3C6E86FF", "0x6E7D3AFF", "0x7A5C3EFF", "0x4E6E6EFF", "0x5B4E7AFF", "0x6E3E4EFF", "0x3E7A66FF"]
    return colors[hash MOD colors.Count()]
end function
