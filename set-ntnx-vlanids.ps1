<#
.SYNOPSIS
  This script is meant to be used after Nutanix nodes have been imaged with vSphere and the VLAN Id for the management network and CVM network need to be configured.
.DESCRIPTION
  Given a csv list of ESXi host IP addresses, the script will: shutdown all the VMs running on the host, change the default "VM Network" port group to add the specified VLAN Id, change the default "Management Network" port group with the specified VLAN Id, at which point connectivity to the host will be lost.  Default user and password are assumed.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER hosts
  Path to a csv file containing all the ESXi hosts management IP addresses.
.PARAMETER vlan
  VLAN Id to be set for the "VM Network" and "Management Network" port groups.
.EXAMPLE
  PS> .\set-ntnx-vlanids.ps1 -hosts .\esxi-hosts.csv -vlan 12
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: December 7th 2015
#>

#region parameters
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
    [parameter(mandatory = $true)] [string]$hosts,
	[parameter(mandatory = $true)] [string]$vlan
)
#endregion

#region functions
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
#endregion

region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}
#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 12/07/2015 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\set-ntnx-vlanids.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}



#let's make sure the VIToolkit is being used
$myvarPowerCLI = Get-PSSnapin VMware.VimAutomation.Core -Registered
try {
    switch ($myvarPowerCLI.Version.Major) {
        {$_ -ge 6}
            {
            Import-Module VMware.VimAutomation.Vds -ErrorAction Stop
            OutputLogData -category "INFO" -message "PowerCLI 6+ module imported"
            }
        5   {
            Add-PSSnapin VMware.VimAutomation.Vds -ErrorAction Stop
            OutputLogData -category "WARNING" -message "PowerCLI 5 snapin added; recommend upgrading your PowerCLI version"
            }
        default {throw "This script requires PowerCLI version 5 or later"}
        }
    }
catch {throw "Could not load the required VMware.VimAutomation.Vds cmdlets"}
#endregion

#region variables
#initialize variables
	#misc variables
	$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
	$myvarvCenterServers = @() #used to store the list of all the vCenter servers we must connect to
	$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
	$myvarOutputLogFile += "OutputLog.log"
#endregion

#region parameters validation
	############################################################################
	# command line arguments initialization
	############################################################################	
	#let's initialize parameters if they haven't been specified
	
	#check specified csv file exists
	#read csv entries into variable
	if (Test-Path $hosts) {$myvarHosts = Get-Content $hosts} else 
		{
			OutputLogData -category "ERROR" -message "$hosts does not exist."
			break
		}
	
	#display warning messages
	$myvarPrompt = Read-Host "Did you shutdown the Nutanix cluster? [y/N]"
	if (($myvarPrompt -ne "y") -and ($myvarPrompt -ne "Y")) {break}
	$myvarPrompt = Read-Host "When this script completes, you will lose connectivity to the ESXi hosts until the physical network ports have been reconfigured with the appropriate VLAN IDs.  Do you understand? [y/N]"
	if (($myvarPrompt -ne "y") -and ($myvarPrompt -ne "Y")) {break}
	$myvarPrompt = Read-Host "This will change the VM Network and Management Network VLAN Id to $vlan on all hosts in $hosts. Is this ok? [y/N]"
	if (($myvarPrompt -ne "y") -and ($myvarPrompt -ne "Y")) {break}
#endregion

#region processing
	################################
	##  foreach ESXi host loop      ##
	################################
	foreach ($myvarHost in $myvarHosts)	
	{
		OutputLogData -category "INFO" -message "Connecting to host $myvarHost..."
		if (!($myvarHostObject = Connect-VIServer $myvarHost -User root -Password 'nutanix/4u'))#make sure we connect to the host OK...
		{#make sure we can connect to the host
			$myvarerror = $error[0].Exception.Message
			OutputLogData -category "ERROR" -message "$myvarerror"
			continue
		}
		else #...otherwise show the error message
		{
			OutputLogData -category "INFO" -message "Connected to host $myvarHost."
		}#endelse
		
		if ($myvarHostObject)
		{
		
			######################
			#main processing here#
			######################
			
			OutputLogData -category "INFO" -message "Shutting down VMs on $myvarHost..."
			get-vm | shutdown-vmguest -Confirm:$false
			OutputLogData -category "INFO" -message "Changing VM Network port group to vlan Id $vlan on $myvarHost..."
			get-virtualportgroup -Name "VM Network" -VirtualSwitch vSwitch0 | set-virtualportgroup -vlanid $vlan
			OutputLogData -category "INFO" -message "Changing Management Network port group to vlan Id $vlan on $myvarHost..."
			get-virtualportgroup -Name "Management Network" -VirtualSwitch vSwitch0 | set-virtualportgroup -vlanid $vlan -RunAsync
			
		}#endif
        OutputLogData -category "INFO" -message "Done processing host $myvarHost..."
	}#end foreach host
#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
	OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar* -ErrorAction SilentlyContinue
	Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
	Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
	Remove-Variable log -ErrorAction SilentlyContinue
	Remove-Variable hosts -ErrorAction SilentlyContinue
	Remove-Variable vlan -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion