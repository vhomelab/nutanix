<#
.SYNOPSIS
  Copy portgroups and security policy on a specified vSwitch from one host to other hosts.
.DESCRIPTION
  This script is meant to be used when you are setting up standard vSwitches as part of a vSphere installation. Provided that you have set up all your portgroups and vSwitch security policy on one host manually, the script will let you specifiy that vSwitch and host as a source and a cluster name or list of host hostnames as a target and will copy all portgroups and the security policy over. 
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER vcenter
  VMware vCenter server hostname. If you don't specify one, the script will prompt you.
.PARAMETER sourceHost
  Name of the source host which contains the desired vSwitch configuration.
.PARAMETER sourcevSwitch
  Name of the vSwitch you want to copy.
.PARAMETER targetHost
  Name of the target host where you want to copy the vSwitch configuration. Multiple hostnames can be specified using a comma separated list.
.PARAMETER targetCluster
  Instead of specifying a target host, you can specify a target cluster.  If the source host is in that cluster, it will be automatically excluded to avoid errors.
.EXAMPLE
  Copy vSwitch0 configuration to all hosts in cluster01 from host hostA:
  PS> .\set-portgroups.ps1 -vcenter myvcenter.local -sourceHost hostA -sourcevSwitch vSwitch0 -targetCluster cluster01
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: December 16th 2015
#>

######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)] [switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $false)] [string]$vcenter,
	[parameter(mandatory = $false)] [string]$sourceHost,
	[parameter(mandatory = $false)] [string]$sourcevSwitch,
	[parameter(mandatory = $false)] [string]$targetHost,
	[parameter(mandatory = $false)] [string]$targetCluster
)

# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}

########################
##   main functions   ##
########################

#this function is used to output log data
Function OutputLogData 
{
	#input: log category, log message
	#output: text to standard output
<#
.SYNOPSIS
  Outputs messages to the screen and/or log file.
.DESCRIPTION
  This function is used to produce screen and log output which is categorized, time stamped and color coded.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER myCategory
  This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".
.PARAMETER myMessage
  This is the actual message you want to display.
.EXAMPLE
  PS> OutputLogData -mycategory "ERROR" -mymessage "You must specify a cluster name!"
#>
	param
	(
		[string] $category,
		[string] $message
	)

    begin
    {
	    $myvarDate = get-date
	    $myvarFgColor = "Gray"
	    switch ($category)
	    {
		    "INFO" {$myvarFgColor = "Green"}
		    "WARNING" {$myvarFgColor = "Yellow"}
		    "ERROR" {$myvarFgColor = "Red"}
		    "SUM" {$myvarFgColor = "Magenta"}
	    }
    }

    process
    {
	    Write-Host -ForegroundColor $myvarFgColor "$myvarDate [$category] $message"
	    if ($log) {Write-Output "$myvarDate [$category] $message" >>$myvarOutputLogFile}
    }

    end
    {
        Remove-variable category
        Remove-variable message
        Remove-variable myvarDate
        Remove-variable myvarFgColor
    }
}#end function OutputLogData

#########################
##   main processing   ##
#########################

#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 12/16/2015 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\set=portgroups.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}



#let's make sure the VIToolkit is being used
if ((Get-PSSnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null)#is it already there?
{
	Add-PSSnapin VMware.VimAutomation.Core #no? let's add it
	if (!$?) #have we been able to add it successfully?
	{
		OutputLogData -category "ERROR" -message "Unable to load the PowerCLI snapin.  Please make sure PowerCLI is installed on this server."
		return
	}
} 
#Initialize-VIToolkitEnvironment.ps1 | Out-Null

#initialize variables
	#misc variables
	$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
	$myvarvCenterServers = @() #used to store the list of all the vCenter servers we must connect to
	$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
	$myvarOutputLogFile += "OutputLog.log"
	
	############################################################################
	# command line arguments initialization
	############################################################################	
	#let's initialize parameters if they haven't been specified
	if (!$vcenter) {$vcenter = read-host "Enter vCenter server name or IP address"}#prompt for vcenter server name
	$myvarvCenterServers = $vcenter.Split(",") #make sure we parse the argument in case it contains several entries
    if (!$sourceHost) {$sourceHost = read-host "Enter name of the source host"}#prompt for source host name
	if (!$sourcevSwitch) {$sourcevSwitch = read-host "Enter name of the source vSwitch"}#prompt for source vSwitch name
	if (!$targetCluster -and !$targetHost)
	{
		$myvarTargetType = read-host "Do you want to target host(s) or a cluster? [H/c] "
		if ($myvarTargetType -eq "c")
		{
			$targetCluster = read-host "Enter the name of the target cluster" #prompt for target cluster name
		}
		else 
		{
			$targetHost = read-host "Enter target Host(s) name (use comma to separate multiple entries)" #prompt for target host(s) name(s)
		}
	}
	if ($targetHost) {$myvarHosts = $targetHost.Split(",")}
	
	################################
	##  foreach vCenter loop      ##
	################################
	foreach ($myvarvCenter in $myvarvCenterServers)	
	{
		OutputLogData -category "INFO" -message "Connecting to vCenter server $myvarvCenter..."
		if (!($myvarvCenterObject = Connect-VIServer $myvarvCenter))#make sure we connect to the vcenter server OK...
		{#make sure we can connect to the vCenter server
			$myvarerror = $error[0].Exception.Message
			OutputLogData -category "ERROR" -message "$myvarerror"
			return
		}
		else #...otherwise show the error message
		{
			OutputLogData -category "INFO" -message "Connected to vCenter server $myvarvCenter."
		}#endelse
		
		if ($myvarvCenterObject)
		{
		
			######################
			#main processing here#
			######################
			
			#get hosts in the cluster
			if ($targetCluster) {$myvarHosts = Get-Cluster -Name $targetCluster | Get-VMHost | where {$_.Name -ne $sourceHost}}
			
			#connect to source host
			OutputLogData -category "INFO" -message "Connecting to source host $sourceHost..."
			if ($myvarSourceHostObject = Get-VMHost -Name $sourceHost*)
			{
				OutputLogData -category "INFO" -message "Connected to source host server $myvarSourceHostObject."
				OutputLogData -category "INFO" -message "Getting configuration for $sourcevSwitch..."
				$myvarvSwitch = $myvarSourceHostObject |Get-VirtualSwitch -Name $sourcevSwitch
				OutputLogData -category "INFO" -message "Enumerating portgroups on $sourcevSwitch..."
				$myvarPortgroups = $myvarSourceHostObject | Get-VirtualPortGroup -Standard -VirtualSwitch $myvarvSwitch.Name | where {$_.VirtualSwitchName -eq $myvarvSwitch.Name}
				OutputLogData -category "INFO" -message "Getting vSwitch security policy for $sourcevSwitch..."
				$myvarSourcevSwitchSecurityPolicy = Get-SecurityPolicy -virtualswitch $myvarvSwitch
			} else {
				$myerror = $error[0].Exception.Message
				OutputLogData -category "ERROR" -message "$myerror"
				return
			}#endifelse
			
			
			foreach ($myvarHost in $myvarHosts)	
			{
				OutputLogData -category "INFO" -message "Processing host $myvarHost..."
				if ($myvarTargetHostObject = Get-VMHost -Name $myvarHost*)
				{
					OutputLogData -category "INFO" -message "Connected to target host server $myvarTargetHostObject."
					
					#let's check to see if the vswitch already exists
					If (($myvarTargetHostObject |Get-VirtualSwitch -Name $myvarvSwitch.Name -ErrorAction SilentlyContinue)-eq $null)
					{
						OutputLogData -category "INFO" -message "Creating Virtual Switch $myvarvSwitch on $myvarHost"
						$myvarNewSwitch = $myvarTargetHostObject |New-VirtualSwitch -Name $myvarvSwitch.Name -NumPorts $myvarvSwitch.NumPorts -Mtu $myvarvSwitch.Mtu
						OutputLogData -category "INFO" -message "Copying security policy on Virtual Switch $myvarvSwitch on $myvarHost"
						Set-SecurityPolicy -VirtualSwitchPolicy (Get-SecurityPolicy -VirtualSwitch $myvarNewSwitch) -AllowPromiscuous $myvarSourcevSwitchSecurityPolicy.AllowPromiscuous -ForgedTransmits $myvarSourcevSwitchSecurityPolicy.ForgedTransmits -MacChanges $myvarSourcevSwitchSecurityPolicy.MacChanges | Out-Null
					}
					else
					{
						OutputLogData -category "INFO" -message "Copying security policy on Virtual Switch $myvarvSwitch on $myvarHost"
						Set-SecurityPolicy -VirtualSwitchPolicy (Get-SecurityPolicy -VirtualSwitch ($myvarTargetHostObject |Get-VirtualSwitch -Name $myvarvSwitch.Name)) -AllowPromiscuous $myvarSourcevSwitchSecurityPolicy.AllowPromiscuous -ForgedTransmits $myvarSourcevSwitchSecurityPolicy.ForgedTransmits -MacChanges $myvarSourcevSwitchSecurityPolicy.MacChanges  | Out-Null
					}#endifelse
					
					#process port groups
					foreach ($myvarPortgroup in $myvarPortgroups)
					{
						$myvarPG = $myvarPortgroup.name
						#create the port group on the target host if it does not exist
						If (($myvarTargetHostObject |Get-VirtualPortGroup -Name $myvarPG -ErrorAction SilentlyContinue)-eq $null)
						{
							OutputLogData -category "INFO" -message "Creating Portgroup $($myvarPortgroup.Name) on $myvarvSwitch on $myvarHost"
							$myvarNewPortGroup = $myvarTargetHostObject |Get-VirtualSwitch -Name $myvarvSwitch.Name |New-VirtualPortGroup -Name $myvarPortgroup.Name-VLanId $myvarPortgroup.VLanID
							OutputLogData -category "INFO" -message "Copying Portgroup security policy for $($myvarPortgroup.Name) on $myvarvSwitch on $myvarHost"
							$myvarPortgroupSecurityPolicy = Get-SecurityPolicy -VirtualPortGroup $myvarPortgroup
							Set-SecurityPolicy -VirtualPortGroupPolicy (Get-SecurityPolicy -VirtualPortGroup $myvarNewPortGroup) -AllowPromiscuous $myvarPortgroupSecurityPolicy.AllowPromiscuous -ForgedTransmits $myvarPortgroupSecurityPolicy.ForgedTransmits -MacChanges $myvarPortgroupSecurityPolicy.MacChanges  | Out-Null
							Set-SecurityPolicy -VirtualPortGroupPolicy (Get-SecurityPolicy -VirtualPortGroup $myvarNewPortGroup) -AllowPromiscuousInherited $myvarPortgroupSecurityPolicy.AllowPromiscuousInherited -ForgedTransmitsInherited $myvarPortgroupSecurityPolicy.ForgedTransmitsInherited -MacChangesInherited $myvarPortgroupSecurityPolicy.MacChangesInherited  | Out-Null
						}
						else
						{
							OutputLogData -category "INFO" -message "Copying Portgroup security policy for $($myvarPortgroup.Name) on $myvarvSwitch on $myvarHost"
							$myvarPortgroupSecurityPolicy = Get-SecurityPolicy -VirtualPortGroup $myvarPortgroup
							Set-SecurityPolicy -VirtualPortGroupPolicy (Get-SecurityPolicy -VirtualPortGroup ($myvarTargetHostObject |Get-VirtualPortGroup -Name $myvarPG)) -AllowPromiscuous $myvarPortgroupSecurityPolicy.AllowPromiscuous -ForgedTransmits $myvarPortgroupSecurityPolicy.ForgedTransmits -MacChanges $myvarPortgroupSecurityPolicy.MacChanges  | Out-Null
							Set-SecurityPolicy -VirtualPortGroupPolicy (Get-SecurityPolicy -VirtualPortGroup ($myvarTargetHostObject |Get-VirtualPortGroup -Name $myvarPG)) -AllowPromiscuousInherited $myvarPortgroupSecurityPolicy.AllowPromiscuousInherited -ForgedTransmitsInherited $myvarPortgroupSecurityPolicy.ForgedTransmitsInherited -MacChangesInherited $myvarPortgroupSecurityPolicy.MacChangesInherited  | Out-Null
						}#endifelse
					}#end foreach port group loop
				}
				else
				{
					$myerror = $error[0].Exception.Message
					OutputLogData -category "ERROR" -message "$myerror"
					return
				}#endifelse
			}#end foreach host loop
		}#endif
        OutputLogData -category "INFO" -message "Disconnecting from vCenter server $vcenter..."
		Disconnect-viserver -Confirm:$False #cleanup after ourselves and disconnect from vcenter
	}#end foreach vCenter
	
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
	OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar*
	Remove-Variable ErrorActionPreference
	Remove-Variable help
    Remove-Variable history
	Remove-Variable log
	Remove-Variable vcenter
    Remove-Variable debug