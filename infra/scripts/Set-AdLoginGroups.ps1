<#
.SYNOPSIS
    Ensures AD security groups for VM login exist and are members of the local
    Administrators / Remote Desktop Users groups.

.DESCRIPTION
    This script runs ON the VM through an Azure managed Run Command (as SYSTEM, in
    Windows PowerShell 5.1) after the VM has joined the domain. It is embedded into
    the deployment with loadTextContent() from infra/modules/adLoginGroups.bicep.

    * Groups are looked up domain-wide by sAMAccountName.
    * Missing groups are created (global security groups) in the delegated OU using
      the domain join account, which is passed as a *protected* Run Command parameter.
    * Built-in local groups are addressed by well-known SID so the script also works
      on localized OS images.

    SECURITY: never write $DomainPassword (or anything derived from it) to the output.
    Run Command output is stored in the VM instance view.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'DomainPassword', Justification = 'Run Command protectedParameters are delivered as strings; the value is encrypted in transit and never echoed.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Run Command protectedParameters are delivered as strings.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are consumed by nested functions.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GroupsOuPath,

    [Parameter(Mandatory = $true)]
    [string]$AdminGroupName,

    [Parameter(Mandatory = $true)]
    [string]$UserGroupName,

    [string]$DomainUserName = '',

    [string]$DomainPassword = '',

    [ValidateSet('true', 'false')]
    [string]$CreateGroups = 'true',

    [int]$MaxAttempts = 10,

    [int]$RetryDelaySeconds = 30
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Set-StrictMode -Version Latest

$administratorsSid = 'S-1-5-32-544'
$remoteDesktopUsersSid = 'S-1-5-32-555'
$groupNamePattern = '^[A-Za-z0-9._-]{1,64}$'

foreach ($name in @($AdminGroupName, $UserGroupName)) {
    if ($name -notmatch $groupNamePattern) {
        throw "Group name '$name' is invalid. Allowed: letters, digits, '.', '_', '-' (max 64)."
    }
}

function Get-DirectoryEntry {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($DomainUserName)) {
        return New-Object System.DirectoryServices.DirectoryEntry($Path)
    }
    return New-Object System.DirectoryServices.DirectoryEntry($Path, $DomainUserName, $DomainPassword)
}

function Get-DomainGroupSid {
    param([string]$Name)

    $rootDse = Get-DirectoryEntry -Path 'LDAP://RootDSE'
    $namingContext = [string]$rootDse.Properties['defaultNamingContext'].Value
    $domainRoot = Get-DirectoryEntry -Path "LDAP://$namingContext"

    $searcher = New-Object System.DirectoryServices.DirectorySearcher($domainRoot)
    $searcher.Filter = "(&(objectCategory=group)(sAMAccountName=$Name))"
    [void]$searcher.PropertiesToLoad.Add('objectSid')
    $result = $searcher.FindOne()
    if ($null -eq $result) {
        return $null
    }
    return New-Object System.Security.Principal.SecurityIdentifier([byte[]]$result.Properties['objectsid'][0], 0)
}

function Add-DomainGroup {
    param([string]$Name, [string]$Description)

    $ou = Get-DirectoryEntry -Path "LDAP://$GroupsOuPath"
    $group = $ou.Children.Add("CN=$Name", 'group')
    $group.Properties['sAMAccountName'].Value = $Name
    # ADS_GROUP_TYPE_GLOBAL_GROUP | ADS_GROUP_TYPE_SECURITY_ENABLED
    $group.Properties['groupType'].Value = -2147483646
    $group.Properties['description'].Value = $Description
    $group.CommitChanges()
    $group.RefreshCache(@('objectSid'))
    return New-Object System.Security.Principal.SecurityIdentifier([byte[]]$group.Properties['objectSid'].Value, 0)
}

function Resolve-LoginGroup {
    param([string]$Name, [string]$Description)

    $sid = Get-DomainGroupSid -Name $Name
    if ($null -ne $sid) {
        Write-Information "AD group '$Name' already exists ($($sid.Value))."
        return $sid
    }
    if ($CreateGroups -ne 'true') {
        throw "AD group '$Name' does not exist and CreateGroups is disabled."
    }
    $sid = Add-DomainGroup -Name $Name -Description $Description
    Write-Information "Created AD group '$Name' in '$GroupsOuPath' ($($sid.Value))."
    return $sid
}

function Add-LocalGroupMemberWithRetry {
    param([string]$LocalGroupSid, [System.Security.Principal.SecurityIdentifier]$MemberSid)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Add-LocalGroupMember -SID $LocalGroupSid -Member $MemberSid.Value -ErrorAction Stop
            Write-Information "Added $($MemberSid.Value) to local group $LocalGroupSid."
            return
        }
        catch [Microsoft.PowerShell.Commands.MemberExistsException] {
            Write-Information "$($MemberSid.Value) is already a member of local group $LocalGroupSid."
            return
        }
        catch {
            # A freshly created group may not have replicated to the DC used by the VM yet.
            if ($attempt -eq $MaxAttempts) {
                throw
            }
            Write-Information "Attempt $attempt/$MaxAttempts to add $($MemberSid.Value) to $LocalGroupSid failed: $($_.Exception.Message). Retrying in $RetryDelaySeconds s."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

try {
    $adminSid = Resolve-LoginGroup -Name $AdminGroupName -Description "Local administrators on $env:COMPUTERNAME"
    $userSid = Resolve-LoginGroup -Name $UserGroupName -Description "Remote Desktop users on $env:COMPUTERNAME"

    Add-LocalGroupMemberWithRetry -LocalGroupSid $administratorsSid -MemberSid $adminSid
    Add-LocalGroupMemberWithRetry -LocalGroupSid $remoteDesktopUsersSid -MemberSid $userSid
}
finally {
    $DomainPassword = $null
}
