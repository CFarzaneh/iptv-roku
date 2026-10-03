' Entry point for the IPTV Player application
sub RunUserInterface()
    screen = CreateObject("roSGScreen")
    m.port = CreateObject("roMessagePort")
    screen.setMessagePort(m.port)
    
    scene = screen.CreateScene("MainScene")
    scene.observeField("exitApp", m.port)
    screen.show()
    
    while true
        msg = wait(0, m.port)
        msgType = type(msg)
        
        if msgType = "roSGScreenEvent"
            if msg.isScreenClosed() then return
        else if msgType = "roSGNodeEvent"
            if msg.getField() = "exitApp"
                screen.close()
                return
            end if
        end if
    end while
end sub
