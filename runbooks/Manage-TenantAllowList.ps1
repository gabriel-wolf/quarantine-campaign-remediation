param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Add", "Check")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Sender,

    [string]$Notes = "Automated sender allow via Logic App",

    [ValidateRange(1, 30)]
    [int]$ExpirationDays = 30,

    [ValidateRange(1, 30)]
    [int]$VerificationAttempts = 12,

    [ValidateRange(1, 60)]
    [int]$VerificationDelaySeconds = 10,

    [string]$TenantId = "contoso.onmicrosoft.com",

    [string]$AppId = "00000000-0000-0000-0000-000000000000",

    [string]$CertificateName = "ExchangeAutomationCert"
)

$ErrorActionPreference = "Stop"
$Connected = $false
$CurrentState = "Unknown"

function Get-CurrentSenderState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $BlockEntries = @(
        Get-TenantAllowBlockListItems `
            -ListType Sender `
            -ListSubType Tenant `
            -Block `
            -Entry $Entry `
            -ErrorAction Stop |
        Where-Object {
            ([string]$_.Value).Trim() -ieq $Entry
        }
    )

    $AllowEntries = @(
        Get-TenantAllowBlockListItems `
            -ListType Sender `
            -ListSubType Tenant `
            -Allow `
            -Entry $Entry `
            -ErrorAction Stop |
        Where-Object {
            ([string]$_.Value).Trim() -ieq $Entry
        }
    )

    if ($BlockEntries.Count -gt 0) {
        return "Block"
    }

    if ($AllowEntries.Count -gt 0) {
        return "Allow"
    }

    return "Unknown"
}

try {
    $Sender = $Sender.Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($Sender)) {
        throw "The sender value cannot be empty."
    }

    if ($Sender -notmatch '^(?:[^@\s]+@)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}$') {
        throw "'$Sender' is not a valid sender email address or domain."
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
    $CurrentState = Get-CurrentSenderState -Entry $Sender

    if ($Action -eq "Check") {
        [ordered]@{
            Status   = "Success"
            Action   = "Check"
            Sender   = $Sender
            Result   = $CurrentState
            Verified = ($CurrentState -eq "Allow")
        } | ConvertTo-Json -Compress

        return
    }

    if ($CurrentState -eq "Block") {
        throw "'$Sender' currently has a block entry. The block entry must be removed before the sender can be allowed."
    }

    $ExpirationDate = (Get-Date).AddDays(
        $ExpirationDays
    ).ToUniversalTime()

    if ($CurrentState -eq "Allow") {
        Set-TenantAllowBlockListItems `
            -ListType Sender `
            -ListSubType Tenant `
            -Entries $Sender `
            -ExpirationDate $ExpirationDate `
            -Notes $Notes `
            -ErrorAction Stop |
        Out-Null

        $Operation = "Updated"
    }
    else {
        New-TenantAllowBlockListItems `
            -ListType Sender `
            -ListSubType Tenant `
            -Allow `
            -Entries $Sender `
            -ExpirationDate $ExpirationDate `
            -Notes $Notes `
            -ErrorAction Stop |
        Out-Null

        $Operation = "Added"
    }

    $Verified = $false
    $AttemptsUsed = 0

    for (
        $Attempt = 1
        $Attempt -le $VerificationAttempts
        $Attempt++
    ) {
        $AttemptsUsed = $Attempt

        if ($Attempt -gt 1) {
            Start-Sleep -Seconds $VerificationDelaySeconds
        }

        $CurrentState = Get-CurrentSenderState -Entry $Sender

        if ($CurrentState -eq "Allow") {
            $Verified = $true
            break
        }

        if ($CurrentState -eq "Block") {
            throw "'$Sender' appeared as a block entry during verification."
        }
    }

    if ($Verified) {
        [ordered]@{
            Status               = "Success"
            Action               = "Add"
            Operation            = $Operation
            Sender               = $Sender
            Result               = "Allow"
            Verified             = $true
            VerificationAttempts = $AttemptsUsed
            ExpirationDays       = $ExpirationDays
            ExpirationDate       = $ExpirationDate.ToString("o")
            Notes                = $Notes
        } | ConvertTo-Json -Compress

        return
    }

    [ordered]@{
        Status               = "Pending"
        Action               = "Add"
        Operation            = $Operation
        Sender               = $Sender
        Result               = $CurrentState
        Verified             = $false
        VerificationAttempts = $AttemptsUsed
        ExpirationDays       = $ExpirationDays
        ExpirationDate       = $ExpirationDate.ToString("o")
        Notes                = $Notes
        Error                = "The add request completed, but the exact allow entry was not visible before the verification timeout."
    } | ConvertTo-Json -Compress
}
catch {
    [ordered]@{
        Status   = "Failed"
        Action   = $Action
        Sender   = $Sender
        Result   = $CurrentState
        Verified = $false
        Error    = $_.Exception.Message
    } | ConvertTo-Json -Compress

    throw
}
finally {
    if ($Connected) {
        Disconnect-ExchangeOnline `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}
