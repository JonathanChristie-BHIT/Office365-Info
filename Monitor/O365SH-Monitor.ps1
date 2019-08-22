﻿<#
.SYNOPSIS
    Gets the Office 365 Health Center messages and incidents.
    Displays on several tabs with the summary providing a dashbord overview

.DESCRIPTION
    This script is designed to run on a scheduled basis.
    It requires and Azure AD Application for your tenant.
    The script will build an HTML page displaying information and links to tenant messages and articles.
    Several tenants configurations can be held.
    Office 365 service health incidents generate email alerts as well as logging to the event log.
    Alternative links can be added (ie to an external dashboard) should data retrieval fail

    Requires Azure AD powershell module (Install-Module AzureAD)

.INPUTS
    None

.OUTPUTS
    None

.EXAMPLE
    PS C:\> O365SH.ps1

.EXAMPLE
    PS C:\> O365SH.ps1 -Tenant Production

.NOTES
    Author:  Jonathan Christie
    Email:   jonathan.christie (at) boilerhouseit.com
    Date:    02 Feb 2019
    PSVer:   2.0/3.0/4.0/5.0
    Version: 2.0.4
    Updated: Single page, monitor only for SysOps
    UpdNote:

    Wishlist:

    Completed:

    Outstanding:

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [String]$configXML = "..\config\profile-test.xml"
)

$swScript = [system.diagnostics.stopwatch]::StartNew()
Write-Verbose "Changing Directory to $PSScriptRoot"
Set-Location $PSScriptRoot
Import-Module "..\common\O365ServiceHealth.psm1"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)] [string]$info
    )
    # verify the Log is setup and if not create the file
    if ($script:loginitialized -eq $false) {
        $script:FileHeader >> $script:logfile
        $script:loginitialized = $True
    }
    $info = $(Get-Date).ToString() + ": " + $info
    $info >> $script:logfile
}

if ([system.IO.path]::IsPathRooted($configXML) -eq $false) {
    #its not an absolute path. Find the absolute path
    $configXML = Resolve-Path $configXML
}
$config = LoadConfig $configXML

[string]$tenantID = $config.TenantID
[string]$appID = $config.AppID
[string]$clientSecret = $config.AppSecret
[string]$rptProfile = $config.TenantShortName
[string]$proxyHost = $config.ProxyHost
[string]$SMTPUser = $config.EmailUser
[string]$SMTPPassword = $config.EmailPassword
[string]$SMTPKey = $config.EmailKey
[string]$pathLogs = $config.LogPath
[string]$evtLogname = $config.EventLog
[string]$evtSource = $config.MonitorEvtSource
[boolean]$checklog = $false
[boolean]$checksource = $false

#Configure local event log
if ($config.UseEventlog -like 'true') {
    [boolean]$UseEventLog = $true
    #check source and log exists
    $checkLog = [System.Diagnostics.EventLog]::Exists("$($evtLogname)")
    $checkSource = [System.Diagnostics.EventLog]::SourceExists("$($evtSource)")
    if ((! $checkLog) -or (! $checkSource)) {
        New-EventLog -LogName $evtLogname -Source $evtSource
    }
}
else { [boolean]$UseEventLog = $false }

# Get Email credentials
# Check for a username. No username, no need for credentials (internal mail host?)
[PSCredential]$emailCreds = $null
if ($smtpuser -notlike '') {
    #Email credentials have been specified, so build the credentials.
    #See readme on how to build credentials files
    $EmailCreds = getCreds $SMTPUser $SMTPPassword $SMTPKey
}

# Build logging variables
#If no path has been specified, use the current script location
if (!$pathLogs) {
    $pathLogs = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
}

#Check and trim the report path
$pathLogs = $pathLogs.TrimEnd("\")
#Build and Check output directories
#Base for logs
if (!(Test-Path $($pathLogs))) {
    New-Item -ItemType Directory -Path $pathLogs
}

if ([system.IO.path]::IsPathRooted($pathLogs) -eq $false) {
    #its not an absolute path. Find the absolute path
    $pathLogs = Resolve-Path $pathLogs
}

# setup the logfile
# If logfile exists, the set flag to keep logfile
$script:DailyLogFile = "$($pathLogs)\O365Monitor-$($rptprofile)-$(Get-Date -format yyMMdd).log"
$script:LogFile = "$($pathLogs)\tmpO365Monitor-$($rptprofile)-$(Get-Date -format yyMMddHHmmss).log"
$script:LogInitialized = $false
$script:FileHeader = "*** Application Information ***"

$evtMessage = "Config File: $($configXML)"
Write-Log $evtMessage
$evtMessage = "Log Path: $($pathLogs)"
Write-Log $evtMessage

#Create event logs if set
[System.Diagnostics.EventLog]$evtCheck=""
if ($UseEventLog) {
    $evtCheck = Get-EventLog -List -ErrorAction SilentlyContinue | Where-Object { $_.LogDisplayName -eq $evtLogname }
    if (!($evtCheck)) {
        New-EventLog -LogName $evtLogname -Source $evtSource
        Write-EventLog -LogName $evtLogname -Source $evtSource -Message "Event log created." -EventId 1 -EntryType Information
    }
}

#Proxy Configuration
if ($config.UseProxy -like 'true') {
    [boolean]$ProxyServer = $true
    $evtMessage = "Using proxy server $($proxyHost) for connectivity"
    Write-Log $evtMessage
}
else {
    [boolean]$ProxyServer = $false
    $evtMessage = "No proxy to be used."
    Write-Log $evtMessage
}

#Connect to Azure app and grab the service status
ConnectAzureAD
[uri]$urlOrca = "https://manage.office.com"
[uri]$authority = "https://login.microsoftonline.com/$($TenantID)"
$authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority
$clientCredential = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.ClientCredential" -ArgumentList $appId, $clientSecret
$authenticationResult = ($authContext.AcquireTokenAsync($urlOrca, $clientCredential)).Result;
$bearerToken = $authenticationResult.AccessToken
if ($null -eq $authenticationResult) {
    $evtMessage = "ERROR - No authentication result for Auzre AD App"
    Write-EventLog -LogName $evtLogname -Source $evtSource -Message "$($rptProfile) : $evtMessage" -EventId 1 -EntryType Error
    Write-Log $evtMessage
}

$authHeader = @{
    'Content-Type'  = 'application/json'
    'Authorization' = "Bearer " + $bearerToken
}


#Script specific
[array]$allMessages = @()
[array]$newIncidents = @()
#Keep a list of known issues in CSV. This is useful if the event log is cleared, or not used.
[string]$knownIssues = ".\knownIssues-$($rptprofile).csv"
[array]$knownIssuesList = @()

if (Test-Path "$($knownIssues)") { $knownIssuesList = Import-Csv $($knownIssues) }




#	Returns the messages about the service over a certain time range.
[uri]$uriMessages = "https://manage.office.com/api/v1.0/$tenantID/ServiceComms/Messages"

if ($ProxyServer) {
    [array]$allMessages = @((Invoke-RestMethod -Uri $uriMessages -Headers $authHeader -Method Get -Proxy $proxyHost -ProxyUseDefaultCredentials).Value)
}
else {
    [array]$allMessages = @((Invoke-RestMethod -Uri $uriMessages -Headers $authHeader -Method Get).Value)
}

if (($null -eq $allMessages) -or ($allMessages.Count -eq 0)) {
    $evtMessage = "ERROR - Cannot retrieve the current status of services - verify proxy and network connectivity."
    Write-EventLog -LogName $evtLogname -Source $evtSource -Message $evtMessage -EventId 1 -EntryType Error
    Write-Log $evtMessage

}
else {
    $evtMessage = "$($allMessages.count) messages returned."
    Write-Log $evtMessage
}

$currentIncidents = @($allMessages | Where-Object { ($_.messagetype -notlike 'MessageCenter') })
$newIncidents = @($currentIncidents | Where-Object { ($_.id -notin $knownIssuesList.id) -and ($null -eq $_.endtime) })

#Get all messages with no end date (open)
#Get events and check event log
#If not logged, create an entry and send an email

if ($newIncidents.count -ge 1) {
    foreach ($item in $newIncidents) {
        #Check event log. If no entry (ID) then write entry
        $evtFind = Get-EventLog -LogName $evtLogname -Source $evtSource -Message "*: $($item.ID)*: $($rptProfile)*" -ErrorAction SilentlyContinue
        #Check known issues list
        if ($null -eq $evtFind) {
            $emailPriority = ""
            Write-Log "Building and attempting to send email"
            $mailMessage = "<b>ID</b>`t`t: $($item.ID)<br/>"
            $mailMessage += "<b>Tenant</b>`t`t: $($rptProfile)<br/>"
            $mailMessage += "<b>Feature</b>`t`t: $($item.WorkloadDisplayName)<br/>"
            $mailMessage += "<b>Status</b>`t`t: $($item.Status)<br/>"
            $mailMessage += "<b>Severity</b>`t`t: $($item.Severity)<br/>"
            $mailMessage += "<b>Start Date</b>`t: $(Get-Date $item.StartTime -f 'dd-MMM-yyyy HH:mm')<br/>"
            $mailMessage += "<b>Last Updated</b>`t: $(Get-Date $item.LastUpdatedTime -f 'dd-MMM-yyyy HH:mm')<br/>"
            $mailMessage += "<b>Incident Title</b>`t: $($item.title)<br/>"
            $mailMessage += "$($item.ImpactDescription)<br/><br/>"
            $emailPriority = Get-Severity "email" $item.severity
			$emailSubject="New issue: $($item.WorkloadDisplayName) - $($item.Status) [$($item.ID)]"
            SendReport $mailMessage $EmailCreds $config $emailPriority $emailSubject
            $evtMessage = $mailMessage.Replace("<br/>", "`r`n")
            $evtMessage = $evtMessage.Replace("<b>", "")
            $evtMessage = $evtMessage.Replace("</b>", "")
            if ($item.severity -in 'SEV0', 'SEV1' ) { $evtErr = 'Error' } else { $evtErr = 'Warning' }
            Write-EventLog -LogName $evtLogname -Source $evtSource -Message $evtMessage -EventId 20 -EntryType $evtErr
            Write-Log $evtMessage
        }
    }
}

[array]$reportClosed = @()
[array]$recentlyClosed = @()
[array]$recentIncidents = @()

#Previously known items (saved list) where there was not an end time
$recentIncidents = $knownIssuesList | Where-Object { ($_.endtime -eq '') }
#Items on current scan (online) where there was and end time
$recentlyClosed = $currentIncidents | Where-Object { ($_.endtime -ne $null) }
#Closed items are previously open items that now have an end time
$reportClosed = $recentlyClosed | Where-Object { $_.id -in $recentIncidents.ID }
#Some items may have been newly added AND closed
$reportClosed += $currentIncidents | Where-Object { $_.id -notin $knownissueslist.ID -and $null -ne $_.endtime }


foreach ($item in $reportClosed) {
    Write-Log "Building and attempting to send closure email"
    $mailMessage = "<b>Incident Closed</b>`t`t: <b>Closed</b><br/>"
    $mailMessage += "<b>Tenant</b>`t`t: $($rptProfile)<br/>"
    $mailMessage += "<b>ID</b>`t`t: $($item.ID)<br/>"
    $mailMessage += "<b>Feature</b>`t`t: $($item.WorkloadDisplayName)<br/>"
    $mailMessage += "<b>Status</b>`t`t: $($item.Status)<br/>"
    $mailMessage += "<b>Severity</b>`t`t: $($item.Severity)<br/>"
    $mailMessage += "<b>Start Time</b>`t: $(Get-Date $item.StartTime -f 'dd-MMM-yyyy HH:mm')<br/>"
    $mailMessage += "<b>Last Updated</b>`t: $(Get-Date $item.LastUpdatedTime -f 'dd-MMM-yyyy HH:mm')<br/>"
    $mailMessage += "<b>End Time</b>`t: <b>$(Get-Date $item.EndTime -f 'dd-MMM-yyyy HH:mm')</b><br/>"
    $mailMessage += "<b>Incident Title</b>`t: $($item.title)<br/>"
    $mailMessage += "$($item.ImpactDescription)<br/><br/>"
    #Add the last action from microsoft to the email only - not to the event log entry (text can be too long)
    $mailWithLastAction = $mailMessage + "<b>Final Update from Microsoft</b>`t:<br/>"
    $lastMessage = Get-htmlMessage ($item.messages.messagetext | Where-Object {$_ -like '*This is the final update*' -or $_ -like '*Final status:*'})
    $lastMessage = "<div style='background-color:azure'>" + $lastMessage.replace("<br><br>", "<br/>") + "</div>"
    $mailWithLastAction += "$($lastMessage)<br/><br/>"
	$emailSubject="Closed: $($item.WorkloadDisplayName) - $($item.Status) [$($item.ID)]"
    SendReport $mailWithLastAction $EmailCreds $config "Normal" $emailSubject
    $evtMessage = $mailMessage.Replace("<br/>", "`r`n")
    $evtMessage = $evtMessage.Replace("<b>", "")
    $evtMessage = $evtMessage.Replace("</b>", "")
    Write-EventLog -LogName $evtLogname -Source $evtSource -Message $evtMessage -EventId 20 -EntryType Information
    Write-Log $evtMessage
}

#Update the know lists if issues. they might not have increased, but end times may have been added.
if ($allMessages.count -gt 0) {
	$currentIncidents | Export-Csv $($knownIssues) -Encoding UTF8 -NoTypeInformation
}

$swScript.Stop()
$evtMessage = "Script runtime $($swScript.Elapsed.Minutes)m:$($swScript.Elapsed.Seconds)s:$($swScript.Elapsed.Milliseconds)ms on $env:COMPUTERNAME`r`n"
$evtMessage += "*** Processing finished ***`r`n"
Write-Log $evtMessage

#Append to daily log file.
Get-Content $script:logfile | Add-Content $script:Dailylogfile
Remove-Item $script:logfile
Remove-Module O365ServiceHealth