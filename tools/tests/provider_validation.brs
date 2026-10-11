' brs --root tools/tests source/DashboardModel.brs source/M3uParser.brs source/ProviderValidation.brs tools/tests/provider_validation.brs
sub main()
    check(providerValidationCode(200, "{""user_info"":{""auth"":1,""status"":""Active""}}", "xtream") = "NONE", "valid numeric auth")
    check(providerValidationCode(200, "{""user_info"":{""auth"":""1"",""status"":"" active ""}}", "xtream") = "NONE", "valid string auth")
    check(providerValidationCode(200, "{""user_info"":{""auth"":true,""status"":""Active""}}", "xtream") = "NONE", "valid boolean auth")
    check(providerValidationCode(403, "blocked", "xtream") = "PROVIDER_ACCESS_DENIED", "HTTP denial is not a password verdict")
    check(providerValidationCode(401, "blocked", "xtream") = "PROVIDER_ACCESS_DENIED", "HTTP authorization denial")
    check(providerValidationCode(-6, "", "xtream") = "PROVIDER_CONNECTION_FAILED", "DNS failure")
    check(providerValidationCode(-28, "", "xtream") = "PROVIDER_CONNECTION_FAILED", "timeout")
    check(providerValidationCode(503, "", "xtream") = "PROVIDER_ERROR", "upstream unavailable")
    check(providerValidationCode(200, "{""user_info"":{""auth"":0}}", "xtream") = "PROVIDER_ACCOUNT_REJECTED", "explicit account rejection")
    check(providerValidationCode(200, "{""user_info"":{""auth"":1,""status"":""Expired""}}", "xtream") = "PROVIDER_ACCOUNT_INACTIVE", "inactive account")
    check(providerValidationCode(200, "[]", "xtream") = "PROVIDER_BAD_RESPONSE", "unexpected response type")
    check(providerValidationCode(200, "{""user_info"":[]}", "xtream") = "PROVIDER_BAD_RESPONSE", "unexpected account type")
    check(providerValidationCode(200, "{""user_info"":{""auth"":1}}", "xtream") = "PROVIDER_BAD_RESPONSE", "missing account status")
    check(providerValidationCode(200, "", "m3u") = "PROVIDER_ERROR", "empty M3U")
    print "Provider validation checks passed"
end sub

sub check(condition as boolean, label as string)
    if not condition
        print "FAILED: " + label
        stop
    end if
end sub
