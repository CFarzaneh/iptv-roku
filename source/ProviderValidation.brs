' Return only fixed error codes. Never relay provider bodies or account details.
function providerValidationCode(httpCode as integer, body as string, providerType as string) as string
    if httpCode <= 0 then return "PROVIDER_CONNECTION_FAILED"
    if httpCode = 401 or httpCode = 403 then return "PROVIDER_ACCESS_DENIED"
    if httpCode <> 200 or body.Len() > 20000000 then return "PROVIDER_ERROR"
    if providerType <> "xtream"
        parsed = ParseM3U(body)
        if parsed.channels.Count() > 0 then return "NONE"
        return "PROVIDER_ERROR"
    end if
    data = ParseJson(body)
    if GetInterface(data, "ifAssociativeArray") = invalid then return "PROVIDER_BAD_RESPONSE"
    if GetInterface(data.user_info, "ifAssociativeArray") = invalid then return "PROVIDER_BAD_RESPONSE"
    auth = data.user_info.auth
    if auth = invalid then return "PROVIDER_BAD_RESPONSE"
    authenticated = (dashboardText(auth) = "1")
    if Type(auth) = "Boolean" or Type(auth) = "roBoolean" then authenticated = (auth = true)
    if not authenticated then return "PROVIDER_ACCOUNT_REJECTED"
    status = LCase(dashboardText(data.user_info.status).Trim())
    if status = "" then return "PROVIDER_BAD_RESPONSE"
    if status <> "active" then return "PROVIDER_ACCOUNT_INACTIVE"
    return "NONE"
end function
