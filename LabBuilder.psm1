﻿#Requires -version 5.0

##########################################################################################################################################
function Get-LabConfiguration {
    [CmdLetBinding(DefaultParameterSetName="Path")]
    [OutputType([XML])]
    param (
        [parameter(Mandatory=$true, ParameterSetName="Path")]
        [String]$Path,

        [parameter(Mandatory=$true, ParameterSetName="Content")]
        [String]$Content
    ) # Param
    If ($Path) {
        If (-not (Test-Path -Path $Path)) {
            Throw "Configuration file $Path is not found."
        } # If
        $Content = Get-Content -Path $Path  
    } # If
    If (($Content -eq $null) -or ($Content -eq '')) {
        Throw "Configuration is empty."
    } # If
    [XML]$Configuration = New-Object -TypeName XML
    $Configuration.LoadXML($Content)
    Return $Configuration
} # Get-LabConfiguration
##########################################################################################################################################

##########################################################################################################################################
function Test-LabConfiguration {
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration
    )

    If ($Configuration.labbuilderconfig -eq $null) {
        Throw "<labbuilderconfig> node is missing from the configuration."
    }

    # Check folders exist
    [String]$VMPath = $Configuration.labbuilderconfig.SelectNodes('settings').vmpath
    If (-not $VMPath) {
        Throw "<settings>\<vmpath> is missing or empty in the configuration."
    }

    If (-not (Test-Path -Path $VMPath)) {
        Throw "The VM Path $VMPath is not found."
    }

    [String]$VHDParentPath = $Configuration.labbuilderconfig.SelectNodes('settings').vhdparentpath
    If (-not $VHDParentPath) {
        Throw "<settings>\<vhdparentpath> is missing or empty in the configuration."
    }

    If (-not (Test-Path -Path $VHDParentPath)) {
        Throw "The VHD Parent Path $VHDParentPath is not found."
    }

    Return $True
} # Test-LabConfiguration
##########################################################################################################################################

##########################################################################################################################################
function Initialize-LabHyperV {
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration
    )
    
    # Install Hyper-V Components
    Write-Verbose "Initializing Lab Hyper-V Components ..."
    
    If ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
        # Desktop OS
        Get-WindowsOptionalFeature -Online -FeatureName *Hyper-V* | Where-Object -Property State -Eq 'Disabled' | Enable-WindowsOptionalFeature -Online
    } Else {
        # Server OS
        Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools
    }

    [String]$MacAddressMinimum = $Configuration.labbuilderconfig.SelectNodes('settings').macaddressminimum
    If (-not $MacAddressMinimum) {
        $MacAddressMinimum = '00155D010600'
    }

    [String]$MacAddressMaximum = $Configuration.labbuilderconfig.SelectNodes('settings').macaddressmaximum
    If (-not $MacAddressMaximum) {
        $MacAddressMaximum = '00155D0106FF'
    }

    Write-Verbose "Configuring Lab Hyper-V Components ..."
    Set-VMHost -MacAddressMinimum $MacAddressMinimum -MacAddressMaximum $MacAddressMaximum
} # Initialize-LabHyperV
##########################################################################################################################################

##########################################################################################################################################
function Get-LabSwitches {
    [OutputType([System.Collections.Hashtable[]])]
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration
    )

    [System.Collections.Hashtable[]]$Switches = @()
    $ConfigSwitches = $Configuration.labbuilderconfig.SelectNodes('switches').Switch
    Foreach ($ConfigSwitch in $ConfigSwitches) {
        [System.Collections.Hashtable[]]$ConfigAdapters = @()
        If ($ConfigSwitch.Adapters) {
            Foreach ($Adapter in $ConfigSwitch.Adapters) {
                $ConfigAdapters += @{ Name = $Adapter.Name; MACAddress = $Adapter.MacAddress }
            }
        }
        $Switches += @{ Name = $ConfigSwitch.Name; Type = $ConfigSwitch.Type; Adapters = $ConfigAdapters } 
    }
    return $Switches
} # Get-LabSwitches
##########################################################################################################################################

##########################################################################################################################################
function Initialize-LabSwitches {
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration,
    
        [Parameter(Mandatory=$true,
        ValueFromPipeline=$true)]
        [System.Collections.Hashtable[]]$Switches
    )
    
    # Create Hyper-V Switches
    Foreach ($Switch in $Switches) {
        If ((Get-VMSwitch | Where-Object -Property Name -eq $Switch.Name).Count -eq 0) {
            [String]$SwitchName = $Switch.Name
            [string]$SwitchType = $Switch.Type
            Write-Verbose "Creating Virtual Switch '$SwitchName' ..."
            Switch ($SwitchType) {
                'External' {
                    New-VMSwitch -Name $SwitchName -SwitchType External
                    If ($Switch.Adapters) {
                        Foreach ($Adapter in $Switch.Adapters) {
                            Add-VMNetworkAdapter -ManagementOS -SwitchName $Switch.Name -Name $Adapter.Name -StaticMacAddress $Adapter.MacAddress
                        }
                    }
                    Break
                } # 'External'
                'Private' {
                    New-VMSwitch -Name $SwitchName -SwitchType Private
                    Break
                } # 'Private'
                'Internal' {
                    New-VMSwitch -Name $SwitchName -SwitchType Internal
                    Break
                } # 'Internal'
                Default {
                    Throw "Unknown Switch Type $SwitchType."
                }
            } # Switch
        } # If
    } # Foreach        

} # Initialize-LabSwitches
##########################################################################################################################################

##########################################################################################################################################
function Get-LabVMTemplates {
    [OutputType([System.Collections.Hashtable[]])]
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration
    )

    [System.Collections.Hashtable[]]$VMTemplates = @()
    [String]$VHDParentPath = $Configuration.labbuilderconfig.SelectNodes('settings').vhdparentpath
    [String]$FromVM=$Configuration.labbuilderconfig.SelectNodes('templates').fromvm
    If (($FromVM -ne $null) -and ($FromVM -ne '')) {
        $Templates = Get-VM -Name $FromVM
        Foreach ($Template in $Templates) {
            [String]$VMTemplateName = $Template.Name
            [String]$VMTemplateSourceVHD = ($Template | Get-VMHardDiskDrive).Path
            [String]$VMTemplateDestVHD = "$VHDParentPath\$([System.IO.Path]::GetFileName($VMTemplateSourceVHD))"
            $VMTemplates += @{ Name = $VMTemplateName; SourceVHD = $VMTemplateSourceVHD; DestVHD = $VMTemplateDestVHD; }
        } # Foreach
    }
    $Templates = $Configuration.labbuilderconfig.SelectNodes('templates').template
    Foreach ($Template in $Templates) {
       [String]$VMTemplateName = $Template.Name
       [String]$VMTemplateSourceVHD = $Template.SourceVHD
       [String]$VMTemplateDestVHD = "$VHDParentPath\$([System.IO.Path]::GetFileName($VMTemplateSourceVHD))"
       $VMTemplates += @{ Name = $VMTemplateName; SourceVHD = $VMTemplateSourceVHD; DestVHD = $VMTemplateDestVHD; }
    } # Foreach
    Return $VMTemplates
} # Get-LabVMTemplates
##########################################################################################################################################

##########################################################################################################################################
function Initialize-LabVMTemplates {
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration,

        [Parameter(Mandatory=$true,
            ValueFromPipeline=$true)]
        [System.Collections.Hashtable[]]$VMTemplates
    )
    
    Foreach ($VMTemplate in $VMTemplates) {
        If (-not (Test-Path $VMTemplate.DestVHD)) {
            # The template VHD isn't in the VHD Parent folder - so copy it there after optimizing it
            Set-ItemProperty -Path $VMTemplate.SourceVHD -Name IsReadOnly -Value $False
            Write-Verbose "Optimizing template source VHD $($VMTemplate.SourceVHD) ..."
            Optimize-VHD -Path $VMTemplate.SourceVHD -Mode Full
            Set-ItemProperty -Path $VMTemplate.SourceVHD -Name IsReadOnly -Value $True
            Write-Verbose "Copying template source VHD $($VMTemplate.SourceVHD) to $($VMTemplate.DestVHD) ..."
            Copy-Item -Path $VMTemplate.SourceVHD -Destination $VMTemplate.DestVHD
            Set-ItemProperty -Path $VMTemplate.DestVHD -Name IsReadOnly -Value $True
        }
    }
} # Initialize-LabVMTemplates
##########################################################################################################################################

##########################################################################################################################################
function Initialize-LabVMs {
    [CmdLetBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [XML]$Configuration
    )
    
    $ExitingVMs = Get-VM

    Foreach ($VM in $Script:VMs) {
        If (($ExistingMVs | Where-Object -Property Name -eq $VM.Name).Count -eq 0) {
            Write-Verbose "Creating VM $($VM.Name) ..."

            # Find the template that this VM uses and get the Parent VHD Path
            [String]$ParentVHDPath = $null
            Foreach ($VMTemplate in $Script:VMTemplates) {
                If ($VMTemplate.Name -eq $VM.Template) {
                    $ParentVHDPath = $VMTemplate.DestVHD
                    Break

                }
            }
            If ($ParentVHDPath -eq $null)
            {
                throw "The template $($VMTemplate.Name) is not available."
            }
            If (-not (Test-Path $ParentVHDPath))
            {
                throw "The template parent VHD $ParentVHDPath can not be found."
            }

            If (-not (Test-Path -Path "$VMPath\$($VM.Name)")) {
                New-Item -Path "$VMPath\$($VM.Name)" -ItemType Directory | Out-Null
            }
            If (-not (Test-Path -Path "$VMPath\$($VM.Name)\Virtual Machines")) {
                New-Item -Path "$VMPath\$($VM.Name)\Virtual Machines" -ItemType Directory | Out-Null
            }
            If (-not (Test-Path -Path "$VMPath\$($VM.Name)\Virtual Hard Disks")) {
                New-Item -Path "$VMPath\$($VM.Name)\Virtual Hard Disks" -ItemType Directory | Out-Null
            }
            $VMBootDiskPath = "$VMPath\$($VM.Name)\Virtual Hard Disks\$($VM.Name) Boot Disk.vhdx"
            If (-not (Test-Path -Path $VMBootDiskPath)) {
                Write-Verbose "Creating VM $($VM.Name) Boot Disk $VMBootDiskPath ..."
                New-VHD -Differencing -Path $VMBootDiskPath -ParentPath $ParentVHDPath | Out-Null

# Because this is a new boot disk create an unattend file and inject it into the VHD
$UnattendContent = [String] @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="offlineServicing">
        <component name="Microsoft-Windows-LUA-Settings" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <EnableLUA>false</EnableLUA>
        </component>
    </settings>
    <settings pass="generalize">
        <component name="Microsoft-Windows-Security-SPP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipRearm>1</SkipRearm>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>0409:00000409</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-SQMApi" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$($VM.ComputerName)</ComputerName>
            <ProductKey>$($VM.ProductKey)</ProductKey>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
            <UserAccounts>
               <AdministratorPassword>
                  <Value>$($VM.AdministratorPassword)</Value>
                  <PlainText>true</PlainText>
               </AdministratorPassword>
            </UserAccounts>
            <RegisteredOrganization>$($Script:DomainName)</RegisteredOrganization>
            <RegisteredOwner>$($Script:DomainName)</RegisteredOwner>
            <DisableAutoDaylightTimeSet>false</DisableAutoDaylightTimeSet>
            <TimeZone>$($VM.TimeZone)</TimeZone>
        </component>
        <component name="Microsoft-Windows-ehome-reg-inf" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="NonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RestartEnabled>true</RestartEnabled>
        </component>
        <component name="Microsoft-Windows-ehome-reg-inf" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="NonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RestartEnabled>true</RestartEnabled>
        </component>
    </settings>
</unattend>
"@
                Write-Verbose "Applying VM $($VM.Name) Unattend File ..."
                $UnattendFile = $ENV:Temp+"\Unattend.xml"
                Set-Content -Path $UnattendFile -Value $UnattendContent | Out-Null
                New-Item -Path c:\TempMount -ItemType Directory | Out-Null
                Mount-WindowsImage -ImagePath $VMBootDiskPath -Path c:\tempMount -Index 1 | Out-Null
                Use-WindowsUnattend –Path c:\TempMount –UnattendPath $UnattendFile | Out-Null
                Copy-Item -Path $UnattendFile -Destination c:\tempMount\Windows\Panther\ -Force | Out-Null
                Dismount-WindowsImage -Path c:\tempMount -Save | Out-Null
                Remove-Item -Path c:\TempMount | Out-Null
                Remove-Item -Path $UnattendFile | Out-Null
            } Else {
                Write-Verbose "VM $($VM.Name) Boot Disk $VMBootDiskPath already exists..."
            }
            New-VM -Name $VM.Name -MemoryStartupBytes $VM.MemoryStartupBytes -Generation 2 -Path $VMPath -VHDPath $VMBootDiskPath -SwitchName $Script:InternetSwitchName | Out-Null
            If (($VM.ProcessorCount -ne $null) -and ($VM.ProcessorCount -ne 0)) {
                Set-VM -Name $VM.Name -ProcessorCount $VM.ProcessorCount
            }
            If (($VM.DataVHDSize -ne $null) -and ($VM.DataVHDSize -gt 0)) {
                $VMDataDiskPath = "$VMPath\$($VM.Name)\Virtual Hard Disks\$($VM.Name) Data Disk.vhdx"
                If (-not (Test-Path -Path $VMDataDiskPath)) {
                    Write-Verbose "Creating VM $($VM.Name) Data Disk $VMDataDiskPath ..."
                    New-VHD -Path $VMDataDiskPath -SizeBytes $VM.DataVHDSize -Dynamic | Out-Null
                } Else {
                    Write-Verbose "VM $($VM.Name) Data Disk $VMDataDiskPath already exists..."
                }
                Add-VMHardDiskDrive -VMName $VM.Name -Path $VMDataDiskPath -ControllerType SCSI -ControllerLocation 1 -ControllerNumber 0 | Out-Null
            }
            For ([int]$Switch=0; $Switch -lt $Script:DomainSiteCount; $Switch++ ) {
                [char]$SiteLetter = [Convert]::ToChar([Convert]::ToByte([Char]'A')+$Switch)
                If ($SiteLetter -in $VM.Networks) {
                    [string]$SwitchName = "$DomainSwitchName $SiteLetter"
                    Add-VMNetworkAdapter -VMName $VM.Name -SwitchName $SwitchName -Passthru | Set-VMNetworkAdapterVlan -Access -VlanId $($Switch+2) | Out-Null
                }
            }
            If ('@' -notin $VM.Networks) {
                Get-VMNetworkAdapter -VMName $VM.Name -Name 'Network Adapter' | Where-Object -Property SwitchName -eq $Script:InternetSwitchName | Remove-VMNetworkAdapter
            }            
        }
    } 
} # Initialize-LabVMs
##########################################################################################################################################

##########################################################################################################################################
Function Install-Lab {
    [CmdLetBinding(DefaultParameterSetName="Path")]
    param (
        [parameter(Mandatory=$true, ParameterSetName="Path")]
        [String]$Path,

        [parameter(Mandatory=$true, ParameterSetName="Content")]
        [String]$Content
    ) # Param

    If ($Path) {
        [XML]$Config = Get-LabConfiguration -Path $Path
    } Else {
        [XML]$Config = Get-LabConfiguration -Content $Content
    }
    # Make sure everything is OK to install the lab
    If (-not (Test-LabConfiguration -Configuration $Config)) {
        return
    }
       
    Initialize-LabHyperV -Configuration $Config

    $Switches = Get-LabSwitches -Configuration $Config
    Initialize-LabSwitches -Configuration $Config -Switches $Switches

    $VMTemplates = Get-LabVMTemplates -Configuration $Config
    Initialize-LabVMTemplates -Configuration $Config -VMTemplates $VMTemplates

    Initialize-LabVMs -Configuration $Config
} # Build-Lab
##########################################################################################################################################

##########################################################################################################################################
Function Uninstall-Lab {
    [CmdLetBinding()]
    param (
    )
} # Remove-Lab
##########################################################################################################################################

##########################################################################################################################################
# Export the Module Cmdlets
Export-ModuleMember -Function Get-LabConfiguration,Test-LabConfiguration, `
    Get-LabSwitches,Initialize-LabSwitches, `
    Get-LabVMTemplates,Initialize-LabVMTemplates, `
    Initialize-LabHyperV,Initialize-LabVMs, `
    Install-Lab,Uninstall-Lab
##########################################################################################################################################
