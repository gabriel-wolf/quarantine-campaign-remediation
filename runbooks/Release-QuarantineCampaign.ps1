param(
    [Parameter(Mandatory = $true)]
    [string]$InternetMessageId,

    [Parameter(Mandatory = $true)]
    [string]$Actions,

    [ValidateRange(1, 30)]
    [int]$VerificationAttempts = 6,

    [ValidateRange(1, 60)]
    [int]$VerificationDelaySeconds = 5,

    [string]$TenantId = "contoso.onmicrosoft.com",

    [string]$AppId = "00000000-0000-0000-0000-000000000000",

    [string]$CertificateName = "ExchangeAutomationCert"
)

$ErrorActionPreference = "Stop"
$Connected = $false

try {
    $InternetMessageIds = @(
        $InternetMessageId -split '\|\|\|' |
        ForEach-Object {
            $_.Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    $ParsedActions = @(
        $Actions -split ',' |
        ForEach-Object {
            $_.Trim().ToLowerInvariant()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    if ($InternetMessageIds.Count -eq 0) {
        throw "No Internet Message IDs were provided."
    }

    $InvalidActions = @(
        $ParsedActions |
        Where-Object {
            $_ -notin @("release", "check")
        }
    )

    if ($InvalidActions.Count -gt 0) {
        throw "Invalid action(s): $($InvalidActions -join ', '). Valid actions are release and check."
    }

    $Cert = Get-AutomationCertificate -Name $CertificateName

    if ($null -eq $Cert) {
        throw "Automation certificate '$CertificateName' was not found."
    }

    Connect-ExchangeOnline `
        -Certificate $Cert `
        -AppID $AppId `
        -Organization $TenantId `
        -ShowBanner:$false `
        -ErrorAction Stop

    $Connected = $true
    $Results = @()

    foreach ($CurrentInternetMessageId in $InternetMessageIds) {
        $ReleaseAttempted = $false
        $CheckResult = $null
        $Verified = $false
        $AttemptsUsed = 0

        try {
            if ($ParsedActions -contains "release") {
                $QuarantineMessages = @(
                    Get-QuarantineMessage `
                        -MessageId $CurrentInternetMessageId `
                        -ErrorAction Stop
                )

                if ($QuarantineMessages.Count -eq 0) {
                    throw "No quarantined message was found."
                }

                foreach ($Message in $QuarantineMessages) {
                    Release-QuarantineMessage `
                        -Identity $Message.Identity `
                        -ReleaseToAll `
                        -Force `
                        -ErrorAction Stop
                }

                $ReleaseAttempted = $true
            }

            if ($ParsedActions -contains "check") {
                $CheckResult = "CannotDetermine"

                for (
                    $Attempt = 1;
                    $Attempt -le $VerificationAttempts;
                    $Attempt++
                ) {
                    $AttemptsUsed = $Attempt

                    if (
                        $Attempt -gt 1 -and
                        $ParsedActions -contains "release"
                    ) {
                        Start-Sleep -Seconds $VerificationDelaySeconds
                    }

                    $QuarantineMessages = @(
                        Get-QuarantineMessage `
                            -MessageId $CurrentInternetMessageId `
                            -ErrorAction Stop
                    )

                    if ($QuarantineMessages.Count -eq 0) {
                        $CheckResult = "CannotDetermine"
                        break
                    }

                    $Statuses = @(
                        $QuarantineMessages |
                        ForEach-Object {
                            [string]$_.ReleaseStatus
                        }
                    )

                    $NotReleasedStatuses = @(
                        $Statuses |
                        Where-Object {
                            $_ -ne "Released"
                        }
                    )

                    if ($NotReleasedStatuses.Count -eq 0) {
                        $CheckResult = "Released"
                        $Verified = $true
                        break
                    }

                    $PendingStatuses = @(
                        $Statuses |
                        Where-Object {
                            $_ -in @(
                                "PreparingToRelease",
                                "Requested",
                                "Approved"
                            )
                        }
                    )

                    if ($PendingStatuses.Count -gt 0) {
                        continue
                    }

                    $OtherStatuses = @(
                        $Statuses |
                        Where-Object {
                            $_ -ne "NotReleased"
                        }
                    )

                    if ($OtherStatuses.Count -eq 0) {
                        $CheckResult = "NotReleased"

                        if ($ParsedActions -notcontains "release") {
                            break
                        }

                        continue
                    }

                    $CheckResult = "CannotDetermine"
                }
            }

            $Results += [PSCustomObject]@{
                InternetMessageId    = $CurrentInternetMessageId
                Status               = "Success"
                Result               = $CheckResult
                Verified             = $Verified
                ReleaseAttempted     = $ReleaseAttempted
                VerificationAttempts = $AttemptsUsed
                Error                = $null
            }
        }
        catch {
            $Results += [PSCustomObject]@{
                InternetMessageId    = $CurrentInternetMessageId
                Status               = "Failed"
                Result               = if ($ParsedActions -contains "check") {
                    "CannotDetermine"
                }
                else {
                    $null
                }
                Verified             = $false
                ReleaseAttempted     = $ReleaseAttempted
                VerificationAttempts = $AttemptsUsed
                Error                = $_.Exception.Message
            }
        }
    }

    $SuccessfulResults = @(
        $Results |
        Where-Object {
            if ($ParsedActions -contains "check") {
                $_.Verified -eq $true
            }
            else {
                $_.Status -eq "Success"
            }
        }
    )

    $FailedResults = @(
        $Results |
        Where-Object {
            if ($ParsedActions -contains "check") {
                $_.Verified -ne $true
            }
            else {
                $_.Status -ne "Success"
            }
        }
    )

    $FailedMessageIds = @(
        $FailedResults |
        ForEach-Object {
            $_.InternetMessageId
        }
    )

    $OverallStatus = if ($FailedResults.Count -eq 0) {
        "Success"
    }
    elseif ($SuccessfulResults.Count -eq 0) {
        "Failed"
    }
    else {
        "PartialSuccess"
    }

    [ordered]@{
        Status           = $OverallStatus
        Actions          = $ParsedActions
        Total            = $Results.Count
        SuccessfulCount  = $SuccessfulResults.Count
        FailedCount      = $FailedResults.Count
        FailedMessageIds = $FailedMessageIds
        Results          = $Results
    } | ConvertTo-Json -Depth 10 -Compress
}
catch {
    [ordered]@{
        Status           = "Failed"
        Actions          = @()
        Total            = 0
        SuccessfulCount  = 0
        FailedCount      = 0
        FailedMessageIds = @()
        Results          = @()
        Error            = $_.Exception.Message
    } | ConvertTo-Json -Depth 10 -Compress

    throw
}
finally {
    if ($Connected) {
        Disconnect-ExchangeOnline `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}
