# Script runtime environment: Level-0 Azure virtual machine ("Client VM")
#
# LocalBoxLogonScript.ps1 - corrected / idempotent version
# Repo path: azure_jumpstart_localbox/artifacts/PowerShell/LocalBoxLogonScript.ps1
#
# Changes vs. original (8 fixes):
#   1. $ErrorActionPreference explicitly set to 'Continue'   (was inherited as 'Stop')
#   2. Set-PSDebug -Strict disabled
#   3. New-StoragePool guarded by existence check
#   4. $diskNum computed with array-safe @() and validated
#   5. New-VirtualDisk guarded by existence check
#   6. Partition/format guarded on the DRIVE LETTER, not partition style
#   7. Desktop shortcut blocks wrapped in try/catch (SYSTEM-safe)
#   8. Write-Host string concatenation corrected
#
# Net effect: the script is safely re-runnable, and the storage section can no
# longer abort the run before New-LocalBoxCluster.ps1 is invoked.
# ---------------------------------------------------------------------------

$ProgressPreference = "SilentlyContinue"

# FIX 1: Bootstrap.ps1 sets this via a machine environment variable, but
# PowerShell never initialises the preference variable from an env var, so the
# session inherited 'Stop'. That turned the cosmetic storage error into a
# terminating one and killed the script before the cluster build.
$ErrorActionPreference = 'Continue'

# FIX 2: Strict mode turns reads of uninitialised variables into hard failures
# (e.g. $disks.Count when $disks is $null).
# Set-PSDebug -Strict

#####################################################################
# Initialize the environment
#####################################################################

# Load config file
$LocalBoxConfig = Import-PowerShellDataFile -Path $Env:LocalBoxConfigFile

Start-Transcript -Path "$($LocalBoxConfig.Paths.LogsDir)\LocalBoxLogonScript.log"

# Login to Azure PowerShell
Connect-AzAccount -Identity -Tenant $Env:tenantId -Subscription $Env:subscriptionId

#####################################################################
# Add RBAC permissions
#####################################################################

#############################################################
# Remove registry keys that are used to automatically logon the user
# (only used for first-time setup)
#############################################################

$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$keys = @("AutoAdminLogon", "DefaultUserName", "DefaultPassword")

foreach ($key in $keys) {
    # FIX 8b: test-then-act instead of throw-then-catch, so re-runs stay quiet.
    if ($null -ne (Get-ItemProperty -Path $registryPath -Name $key -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $registryPath -Name $key -ErrorAction SilentlyContinue
        Write-Host "Removed registry key used to automatically logon the user: $key"
    }
    else {
        Write-Verbose "Key $key does not exist (expected on re-runs)."
    }
}

#############################################################
# Create desktop shortcut for Logs-folder
#############################################################

# FIX 7: fails gracefully when running as SYSTEM (no Desktop folder).
try {
    $desktopPath = "$Env:USERPROFILE\Desktop"
    if (-not (Test-Path $desktopPath)) {
        New-Item -Path $desktopPath -ItemType Directory -Force | Out-Null
    }

    $WshShell = New-Object -comObject WScript.Shell
    $LogsPath = "C:\LocalBox\Logs"
    $Shortcut = $WshShell.CreateShortcut("$desktopPath\Logs.lnk")
    $Shortcut.TargetPath  = $LogsPath
    $Shortcut.WindowStyle = 3
    $Shortcut.Save()
    Write-Host "Created Logs desktop shortcut."
}
catch {
    Write-Warning "Could not create Logs shortcut: $($_.Exception.Message)"
}

# Creating Hyper-V Manager desktop shortcut
Write-Host 'Creating Hyper-V Shortcut'

# FIX 7b: source .lnk may not exist until Hyper-V management tools finish installing.
try {
    Copy-Item -Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk' `
              -Destination 'C:\Users\All Users\Desktop' -Force -ErrorAction Stop
}
catch {
    Write-Warning "Could not copy Hyper-V Manager shortcut: $($_.Exception.Message)"
}

#############################################################
# Configure Windows Terminal as the default terminal application
#############################################################

$registryPath = "HKCU:\Console\%%Startup"

if (-not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}
Set-ItemProperty -Path $registryPath -Name "DelegationConsole"  -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
Set-ItemProperty -Path $registryPath -Name "DelegationTerminal" -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"

#############################################################
# Install VSCode extensions
#############################################################

# FIX 8: '+' does not concatenate in argument position; it was passed as an
# extra positional argument, producing "extensions:  + ms-vscode-remote..." in the log.
Write-Host "[$(Get-Date -Format t)] INFO: Installing VSCode extensions: $($LocalBoxConfig.VSCodeExtensions -join ', ')" -ForegroundColor Gray

foreach ($extension in $LocalBoxConfig.VSCodeExtensions) {
    $WarningPreference = "SilentlyContinue"
    code --install-extension $extension 2>&1 |
        Out-File -Append -FilePath ($LocalBoxConfig.Paths.LogsDir + "\Tools.log")
    $WarningPreference = "Continue"
}

#####################################################################
# Configure virtualization infrastructure
#####################################################################

Write-Header "Configuring storage"

$poolName  = 'AzLocalPool'
$vdiskName = 'AzLocalDisk'
$driveLtr  = $LocalBoxConfig.HostVMDriveLetter

# FIX 3: create the pool only when it does not already exist. On re-runs the
# disks are already claimed, so Get-PhysicalDisk -CanPool $true returns nothing
# and the parameter validator rejects the empty argument.
if (-not (Get-StoragePool -FriendlyName $poolName -ErrorAction SilentlyContinue)) {

    $poolDisks = Get-PhysicalDisk -CanPool $true

    if ($poolDisks) {
        Write-Host "Creating storage pool $poolName from $(@($poolDisks).Count) disk(s)."
        New-StoragePool -FriendlyName $poolName `
                        -StorageSubSystemFriendlyName '*storage*' `
                        -PhysicalDisks $poolDisks
    }
    else {
        Write-Warning "No poolable disks found and no $poolName pool exists."
        Write-Warning "Diagnose with: Get-PhysicalDisk | Select DeviceId,CanPool,CannotPoolReason"
    }
}
else {
    Write-Host "Storage pool $poolName already exists. Skipping creation."
}

# FIX 4: @() forces array semantics so .Count is valid for $null or a single
# object, preventing an invalid NumberOfColumns value below.
$disks   = Get-StoragePool -FriendlyName $poolName -IsPrimordial $False -ErrorAction SilentlyContinue |
           Get-PhysicalDisk -ErrorAction SilentlyContinue
$diskNum = @($disks).Count

Write-Host "Physical disks in pool: $diskNum"

# FIX 5: create the virtual disk only when absent. The first run consumed the
# whole pool via -UseMaximumSize, so a second attempt reports
# "insufficient eligible resources".
if (-not (Get-VirtualDisk -FriendlyName $vdiskName -ErrorAction SilentlyContinue)) {

    if ($diskNum -ge 1) {
        Write-Host "Creating virtual disk $vdiskName across $diskNum column(s)."
        New-VirtualDisk -StoragePoolFriendlyName $poolName `
                        -FriendlyName $vdiskName `
                        -ResiliencySettingName Simple `
                        -NumberOfColumns $diskNum `
                        -UseMaximumSize
    }
    else {
        Write-Warning "Pool contains no physical disks - skipping virtual disk creation."
    }
}
else {
    Write-Host "Virtual disk $vdiskName already exists. Skipping creation."
}

# FIX 6: guard on the drive letter (the real desired end state) rather than on
# partition style. After a successful first run the disk is GPT, so the original
# elseif branch re-ran New-Partition and failed with
# "The requested access path is already in use".
if (-not (Get-Volume -DriveLetter $driveLtr -ErrorAction SilentlyContinue)) {

    $vDisk = Get-VirtualDisk -FriendlyName $vdiskName -ErrorAction SilentlyContinue

    if ($vDisk) {
        if ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'raw') {
            Write-Host "Initializing RAW disk and creating volume $driveLtr`:"
            $vDisk | Get-Disk |
                Initialize-Disk -Passthru |
                New-Partition -DriveLetter $driveLtr -UseMaximumSize |
                Format-Volume -NewFileSystemLabel AzLocalData -AllocationUnitSize 64KB -FileSystem NTFS
        }
        elseif ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'GPT') {
            Write-Host "Creating partition on GPT disk as volume $driveLtr`:"
            $vDisk | Get-Disk |
                New-Partition -DriveLetter $driveLtr -UseMaximumSize |
                Format-Volume -NewFileSystemLabel AzLocalData -AllocationUnitSize 64KB -FileSystem NTFS
        }
    }
    else {
        Write-Warning "Virtual disk $vdiskName not found - cannot create volume $driveLtr`:"
    }
}
else {
    Write-Host "Volume $driveLtr`: already exists. Skipping partition/format."
}

# FIX 6b: New-LocalBoxCluster.ps1 writes nested VMs to $LocalBoxConfig.HostVMPath
# (V:\VMs). Ensure it exists before the build starts.
if (-not (Test-Path $LocalBoxConfig.HostVMPath)) {
    New-Item -Path $LocalBoxConfig.HostVMPath -ItemType Directory -Force | Out-Null
    Write-Host "Created $($LocalBoxConfig.HostVMPath)"
}

# Storage verdict - records definitive state in the transcript.
Write-Host ""
Write-Host "--- Storage verdict ---"
$poolOk = [bool](Get-StoragePool -FriendlyName $poolName  -ErrorAction SilentlyContinue)
$vdOk   = [bool](Get-VirtualDisk -FriendlyName $vdiskName -ErrorAction SilentlyContinue)
$volOk  = [bool](Get-Volume      -DriveLetter  $driveLtr  -ErrorAction SilentlyContinue)
$pathOk = Test-Path $LocalBoxConfig.HostVMPath

Write-Host ("  Pool   {0} : {1}" -f $poolName,  $(if ($poolOk) {'OK'} else {'MISSING'}))
Write-Host ("  VDisk  {0} : {1}" -f $vdiskName, $(if ($vdOk)   {'OK'} else {'MISSING'}))
Write-Host ("  Volume {0}: : {1}" -f $driveLtr, $(if ($volOk)  {'OK'} else {'MISSING'}))
Write-Host ("  Path   {0} : {1}" -f $LocalBoxConfig.HostVMPath, $(if ($pathOk) {'OK'} else {'MISSING'}))
Write-Host ""

if (-not ($poolOk -and $vdOk -and $volOk -and $pathOk)) {
    Write-Warning "Storage is incomplete. The cluster build will likely fail."
}

Stop-Transcript

#####################################################################
# Build Azure Local cluster
#####################################################################
# This is the line the original run never reached. New-LocalBoxCluster.ps1
# performs the 11-step build: Step 1/11 downloads the nested-VM VHDX files,
# later steps create AzLMGMT, AzLHOST1 and AzLHOST2 and Arc-onboard the nodes.

# FIX 1b: report build failures explicitly instead of ending silently.
try {
    & "$Env:LocalBoxDir\New-LocalBoxCluster.ps1"
}
catch {
    Write-Warning "New-LocalBoxCluster.ps1 failed: $($_.Exception.Message)"
    Write-Warning "Review C:\LocalBox\Logs\New-LocalBoxCluster.log for the failing step."
}

Start-Transcript -Append -Path "$($LocalBoxConfig.Paths.LogsDir)\LocalBoxLogonScript.log"

# Removing the LogonScript Scheduled Task so it won't run on next reboot
Write-Header "Removing Logon Task"
Unregister-ScheduledTask -TaskName "LocalBoxLogonScript" -Confirm:$false -ErrorAction SilentlyContinue

# Changing to Jumpstart LocalBox wallpaper
Write-Header "Changing wallpaper"

# bmp file is required for BGInfo
try {
    Convert-JSImageToBitMap -SourceFilePath      "$Env:LocalBoxDir\wallpaper.png" `
                            -DestinationFilePath "$Env:LocalBoxDir\wallpaper.bmp"
    Set-JSDesktopBackground -ImagePath "$Env:LocalBoxDir\wallpaper.bmp"
}
catch {
    Write-Warning "Could not set wallpaper: $($_.Exception.Message)"
}

# Pester suite: verifies nested VMs exist and are running, Arc connected
# machines are registered and Connected, and (when autoDeployClusterResource
# is enabled) the Azure Local instance is in a "Connected" state.
Write-Header "Running tests to verify infrastructure"
& "$Env:LocalBoxTestsDir\Invoke-Test.ps1"

Write-Header "Creating deployment logs bundle"

$RandomString = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$LogsBundleTempDirectory = "$Env:windir\TEMP\LogsBundle-$RandomString"
$null = New-Item -Path $LogsBundleTempDirectory -ItemType Directory -Force

# required to avoid "file is being used by another process" error when compressing
Copy-Item -Path "$($LocalBoxConfig.Paths.LogsDir)\*.log" -Destination $LogsBundleTempDirectory -Force -PassThru
Compress-Archive -Path "$LogsBundleTempDirectory\*.log" `
                 -DestinationPath "$($LocalBoxConfig.Paths.LogsDir)\LogsBundle-$RandomString.zip" -PassThru

Stop-Transcript
