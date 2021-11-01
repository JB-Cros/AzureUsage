﻿param (
    [string]$startDate = (Get-Date).AddDays(-31).tostring(“MM-dd-yyyy”),  # defaults to 30 days prior to last collection date
    [string]$endDate   = (Get-Date).AddDays(-1).tostring(“MM-dd-yyyy”),   # last current collection date
    [ValidateSet("True", "False")]
    [string]
    $includeDetail = "True"                                           # only shows subscription totals if false - add _Summary if false, or _Detail if true
)

# Program documentation


# Variable definitions

$reportType = "_Summary.txt"

if ($includeDetail -eq "$True")
{
    $reportType = "_Detail.txt"
}

$outputFile = ("C:\Users\jgange\Projects\PowerShell\AzureUsage\AzureUsageReport_" + $startDate + "_" + $endDate + $reportType).Replace("/","-")

Write-Host "Running with the following settings- Start date: $startDate    End date: $endDate    Detail level: $includeDetail"

if ($includeDetail)
{
    $reportType = "_Detail.txt"
}

# Storage for Azure resources and subscriptions
$azureSubscriptions  = @()                                                                                        # Stores available subscriptions
$azureResources      = [System.Collections.ArrayList]@()                                                          # List of all accessible Azure resources across all subscriptions
$resourceUsageReport = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))    # Thread safe array to hold finally aggregated report data
$resourceQ           = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())                # queue to hold collection of resources per subscriptions

# Set max # of concurrent threads
$offset = 3
[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + $offset)


# Storage for threaded usage data
$dateQ              = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureUsageRecords  = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# define information for usage data based on date range
$startDate = [datetime]$startDate
$endDate = [datetime]$endDate
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days

# Add the days to look up usage data
0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

# define script block to get Azure usage information
$scriptblock = {
 param(
        $dateQ,
        $azureUsageRecords
    )

    [datetime]$sd = $dateQ.Dequeue()
    $ed = $sd.AddDays(1)
    # Write-Output "Fetching usage records for $sd to $ed"

    do {    
        ## Define all parameters to pass to Get-UsageAggregates
        $params = @{
            ReportedStartTime      = $sd
            ReportedEndTime        = $ed
            #AggregationGranularity = "Hourly"
            AggregationGranularity = "Daily"
            ShowDetails            = $true
        }

        ## Only use the ContinuationToken parameter if this is not the first run
        if ((Get-Variable -Name usageData -ErrorAction Ignore) -and $usageData) {
            Write-Verbose -Message "Querying usage data with continuation token $($usageData.ContinuationToken)..."
            $params.ContinuationToken = $usageData.ContinuationToken
        }

        ((Get-UsageAggregates @params).UsageAggregations | Select-Object -ExpandProperty Properties) | ForEach-Object {
        
            $ur = New-Object PSObject -Property ([ordered]@{
                "Resource Id"          = ((($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)).ToLower()
                "Meter Category"       = $_.MeterCategory
                "Meter Name"           = $_.MeterName
                "Meter SubCategory"    = $_.MeterSubCategory
                "Quantity"             = $_.Quantity
                "Unit"                 = $_.Unit
                "Usage Start Time"     = $_.UsageStartTime
                "Usage End Time"       = $_.UsageEndTime
                "Duration"             = ($_.UsageEndTime - $_.UsageStartTime).hours
                "SubscriptionId"       = ((($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri).split("/")[2]).ToLower()
            })

            [System.Threading.Monitor]::Enter($azureUsageRecords.syncroot)
            [void]$azureUsageRecords.Add($ur)
            [System.Threading.Monitor]::Exit($azureUsageRecords.syncroot)
        }

    } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)

}


# Retrieves resources from all accessible subscriptions
Function getAzureResources()
{
    $global:azureSubscriptions = Get-AzSubscription

    $snum = 0

    $global:azureSubscriptions | ForEach-Object {

        $pc = [math]::Round(($snum/$azureSubscriptions.Count)*100)

        Write-Progress -Activity "Getting Azure resources for all subscriptions" -Status "Working on subscription: $($_.Name) - Percent complete $pc%" -PercentComplete $pc

        $azs = $_.SubscriptionId
        # Write-Output "Setting subscription context to subscription $($_.Name) and retrieving all Azure resources"
        Set-AzContext -Subscription $_.SubscriptionId | Out-Null
        Get-AzResource | ForEach-Object {
            $resourceRecord = New-Object PSObject -Property ([ordered]@{
                "SubscriptionId"        = $azs.ToLower()
                "ResourceName"          = $_.ResourceName
                "ResourceGroupName"     = $_.ResourceGroupName
                "ResourceType"          = $_.ResourceType
                "ResourceId"            = $_.ResourceId
                "Location"              = $_.Location
                "SKUName"               = $_.Sku.Name
                "ParentResource"        = $_.ParentResource
                "Status"                = $_.Properties.provisioningstate
                })
         [void]$azureResources.Add($resourceRecord)
        }
        $snum++
    }
}

Function getResourceUsage([string]$subscriptionId, [string]$resourceId)
{
    # filter the usage records by subscription to reduce the # of comparisons necessary

    $resource = $azureResources -match $resourceId

    $usageBySubscription = $azureUsageRecords.Where({ $_.SubscriptionId -eq $subscriptionId})

    if ($recordList = ($usageBySubscription -match $resourceId))
    {
        $usage = (($recordList | Measure-Object -Property Quantity -Sum).Sum)

        $entry = New-Object PSObject -Property ([ordered]@{
                "ResourceName"          = $resource.ResourceName
                "ResourceGroupName"     = $resource.ResourceGroupName
                "ResourceType"          = $resource.ResourceType
                "ResourceId"            = $resource.ResourceId
                "Location"              = $resource.Location
                "SKUName"               = $resource.Sku.Name
                "ParentResource"        = $resource.ParentResource
                "Status"                = $resource.Properties.provisioningstate
                "Usage"                 = $usage
                "Unit"                  = $recordList[-1].Unit
                "Meter Category"        = $recordList[-1]."Meter Category"
                "Meter SubCategory"     = $recordList[-1]."Meter SubCategory"
                "Meter Name"            = $recordList[-1]."Meter Name"
                })
         [void]$resourceUsageReport.Add($entry)
    }
    else
    {
          $entry = New-Object PSObject -Property ([ordered]@{
                "ResourceName"          = $resource.ResourceName
                "ResourceGroupName"     = $resource.ResourceGroupName
                "ResourceType"          = $resource.ResourceType
                "ResourceId"            = $resource.ResourceId
                "Location"              = $resource.Location
                "SKUName"               = $resource.Sku.Name
                "ParentResource"        = $resource.ParentResource
                "Status"                = $resource.Properties.provisioningstate
                "Usage"                 = 0
                "Unit"                  = "n/a"
                "Meter Category"        = "n/a"
                "Meter SubCategory"     = "n/a"
                "Meter Name"            = "n/a"
                })
         [void]$resourceUsageReport.Add($entry)
    }

}


### Main Program ###

# Check if a connection to Azure exists
if (!($azc.Context.Tenant))
{
    $azc = Connect-AzAccount
}

# Retrieve all the Azure resources
getAzureResources

# Loop through subscriptions to get all the data

$snum = 0

$azureSubscriptions | ForEach-Object {

# Add the days to look up usage data
0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

# Create the Runspace pool and an empty array to store the runspaces
$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxpoolsize)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

$null = (Set-AzContext -Subscription $_.Id)

#Write-Host "Setting subscription to $($_.Name)"
$pc = [math]::Round(($snum/$azureSubscriptions.Count)*100)

Write-Progress -Activity "Getting Usage data for all subscriptions" -Status "Working on subscription: $($_.Name) - Percent complete $pc%" -PercentComplete $pc

# Spin up tasks to get the usage data
1..$numDays | ForEach-Object {
   $runspace = [PowerShell]::Create()
   $null = $runspace.AddScript($scriptblock)
   $null = $runspace.AddArgument($dateQ)
   $null = $runspace.AddArgument($azureUsageRecords)
   $runspace.RunspacePool = $pool
   $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
}

# Check tasks status until they are complete, then close them
while ($runspaces.Status -ne $null)
{
   $completed = $runspaces | Where-Object { $_.Status.IsCompleted -eq $true }
   foreach ($runspace in $completed)
   {
       $runspace.Pipe.EndInvoke($runspace.Status)
       $runspace.Status = $null
   }
}

# Clean up runspaces and free the memory for the pool

$runspaces.Clear()
$pool.Close()
$pool.Dispose()

$snum++

} # End subscription loop

Write-Progress -Completed -Activity "Getting Usage data for all subscriptions"

Start-Transcript -Path $outputFile

Write-Host "`nDate Range: $startDate - $endDate`n"

$azureSubscriptions | ForEach-Object {

    $subId = $_.Id
    $subName = $_.Name

    Write-Host "`n`nSubscription name: $subName`n"

    '{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f "Resource Name","Total Usage","Unit","Location","Resource Type","Meter Category"
    '{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f "-------------","-----------","----","--------","-------------","--------------"

    $usageBySubscription = $azureUsageRecords.Where({$_.SubscriptionId -eq $subId})

    $resourceGrouping = $usageBySubscription | Group-Object -Property "Resource Id"
     
    $resourceGrouping | ForEach-Object {

        $ridm = $_.Group."Resource Id" | Get-Unique                                    # Get list of resource Ids after grouping by resource Id
 
        $totalUsage = ($_.Group | Measure-Object -Property Quantity -Sum).Sum
        
        $mc = $_.Group."Meter Category" | Get-Unique
        
        $un = $_.Group.Unit | Get-Unique
        if ($un.GetType().Name -ne 'String') {
            $unit =  ([String]::Join("-",($un | Sort-Object | Get-Unique))).Split("-")[0]
        }
        else { $unit =  $un }



        if( ($mc.GetType()).Name -ne 'String') 
        { 
            $meterCategory = [String]::Join(" ",($mc | Sort-Object | Get-Unique))
        }
        else
        {
            $meterCategory = $mc
        }

        $resource = $azureResources -match $ridm
        
        if (!($resource))
        {
            $resourceName =      "Not Found"
            $resourceType =      "N/A"
            if ($_.Group."Instance Location") 
            {
                $resourceLocation =  ($_.Group."Instance Location")[0]
            }
            else
            {
                $resourceLocation = "N/A"
            } 
        }
        else
        {
            if ($resource.ResourceName.GetType().Name -ne 'String')
            {
                $resourceName = ($resource.ResourceName)[0]
                #$resourceName = [String]::Join(" ",($resource.ResourceName | Sort-Object | Get-Unique))
            }
            else
            {
                $resourceName     = $resource.ResourceName
                $resourceLocation = $resource.Location
                $resourceType     = $resource.ResourceType
            }
        }

        '{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f $resourceName, $totalUsage, $unit, $resourceLocation, $resourceType, $meterCategory


    }

}

Stop-Transcript

# strip the transcript info out of the file
(Get-Content $outputFile | Select-Object -Skip 19) | Select-Object -SkipLast 4 |Set-Content $outputFile