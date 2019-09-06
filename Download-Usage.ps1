# List of Environments keyed by name, and the value is the system domain
$targetPath = Join-Path $PSScriptRoot "environments.txt"
$targets = ConvertFrom-StringData ([io.file]::ReadAllText($targetPath))

#Ensure TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#Needed to trust certs
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$syncOrgAppUsage = "app"
$syncOrgTaskUsage = "task"
$syncOrgServiceUsage = "service"

function Export-PlatformUsage ([string]$SysDomain, [string]$Type, [string]$Path, [string]$Platform) {
    $platformReport = Invoke-RestMethod "https://app-usage.$SysDomain/system_report/$Type" -Headers @{Authorization="$(cf oauth-token)"}
    if($?) {
        $reportOutput = (
            $platformReport.monthly_reports | select-object @{Name="month"; Expression={$_.month}},
                @{Name="year"; Expression={$_.year}},
                @{Name="average_app_instances"; Expression={$_.average_app_instances}},
                @{Name="maximum_app_instances"; Expression={$_.maximum_app_instances}},
                @{Name="app_instance_hours"; Expression={$_.app_instance_hours}},
                @{Name="report_time"; Expression={$platformReport.report_time}},
                @{Name="platform"; Expression={$Platform}}
            )
        if(Test-Path $Path -PathType Leaf) {
            $reportOutput | Export-CSV -NoTypeInformation -Path "$Path" -Append
        } else {
            $reportOutput | Export-CSV -NoTypeInformation -Path "$Path"
        }
    }
}

$creds = Get-Credential -Message "Enter your FEAD Shortname and Password"
if(!$creds){ exit }

$OrgScript = {
    Param (
        [string]$platform,
        $org,
        [string]$system_domain,
        [string]$token,
        [string]$environment,
        [string]$path,
        $appLock,
        $taskLock,
        $serviceLock
    )
    # First day of the first month the org existed
    $startDateTime = ([DateTime]$org.metadata.created_at)
    $startDateTime = $startDateTime.AddDays(-($startDateTime.Day-1))

    # Last day of first month
    $endDateTime = $startDateTime.AddMonths(1).AddDays(-$startDateTime.Day)

    # Last day of current month
    [DateTime]$stopDate = [DateTime]::Now
    $stopDate = $stopDate.AddMonths(1).AddDays(-($stopDate.Day-1))
    
    # Stop when we move to the month after this one
    while( $startDateTime -lt $stopDate ) {

        $startDate = $startDateTime.ToString("yyyy-MM-dd")
        $endDate = $endDateTime.ToString("yyyy-MM-dd")

        # Org App Usage
        $orgAppReport = Invoke-RestMethod "https://app-usage.$system_domain/organizations/$($org.metadata.guid)/app_usages?start=$startDate&end=$endDate" -Headers @{Authorization="$token"}
        $org_app_usages = (
            $orgAppReport.app_usages | select-object @{Name="space_name"; Expression={$_.space_name}},
                @{Name="app_name"; Expression={$_.app_name}},
                @{Name="app_guid"; Expression={$_.app_guid}},
                @{Name="instance_count"; Expression={$_.instance_count}},
                @{Name="memory_in_mb_per_instance"; Expression={$_.memory_in_mb_per_instance}},
                @{Name="duration_in_seconds"; Expression={$_.duration_in_seconds}},
                @{Name="organization_name"; Expression={$org.entity.name}},
                @{Name="organization_guid"; Expression={$orgAppReport.organization_guid}},
                @{Name="period_start"; Expression={$orgAppReport.period_start}},
                @{Name="period_end"; Expression={$orgAppReport.period_end}},
                @{Name="platform"; Expression={$platform}}
        )
        if($org_app_usages.Count -gt 0) {
            $orgAppUsagePath = Join-Path $path "org-app-usage.csv"
            [bool]$lockTaken = $false
            try {
                [System.Threading.Monitor]::Enter($appLock)
                $lockTaken = $true
                if(Test-Path $orgAppUsagePath -PathType Leaf) {
                    $org_app_usages | Export-Csv -NoTypeInformation -Path $orgAppUsagePath -Append
                } else {
                    $org_app_usages | Export-Csv -NoTypeInformation -Path $orgAppUsagePath
                }
            }
            finally {
                if($lockTaken) { [System.Threading.Monitor]::Exit($appLock) }
            }
        }

        # Org Task Usage
        [System.Collections.ArrayList]$org_task_usages = @()
        $orgTaskReport = Invoke-RestMethod "https://app-usage.$system_domain/organizations/$($org.metadata.guid)/task_usages?start=$startDate&end=$endDate" -Headers @{Authorization="$token"}
        foreach($space in $orgTaskReport.spaces) {
            foreach($space_summary in $space.PSObject.Properties) {
                foreach($task_summary in $space_summary.Value.task_summaries) {
                    $org_task_usages += ($task_summary | select-object @{Name="parent_application_guid"; Expression={$_.parent_application_guid}},
                        @{Name="parent_application_name"; Expression={$_.parent_application_name}},
                        @{Name="memory_in_mb_per_instance"; Expression={$_.memory_in_mb_per_instance}},
                        @{Name="task_count_for_range"; Expression={$_.task_count_for_range}},
                        @{Name="total_duration_in_seconds_for_range"; Expression={$_.total_duration_in_seconds_for_range}},
                        @{Name="max_concurrent_task_count_for_parent_app"; Expression={$_.max_concurrent_task_count_for_parent_app}},
                        @{Name="organization_name"; Expression={$org.entity.name}},
                        @{Name="organization_guid"; Expression={$orgTaskReport.organization_guid}},
                        @{Name="period_start"; Expression={$orgTaskReport.period_start}},
                        @{Name="period_end"; Expression={$orgTaskReport.period_end}},
                        @{Name="space_name"; Expression={$space_summary.Value.space_name}},
                        @{Name="space_guid"; Expression={$space_summary.Name}},
                        @{Name="platform"; Expression={$platform}}
                    )
                }
            }
        }
        if($org_task_usages.Count -gt 0) {
            $orgTaskUsagePath = Join-Path $path "org-task-usage.csv"
            [bool]$lockTaken = $false
            try {
                [System.Threading.Monitor]::Enter($taskLock)
                $lockTaken = $true
                if(Test-Path $orgTaskUsagePath -PathType Leaf ) {
                    $org_task_usages | Export-Csv -NoTypeInformation -Path $orgTaskUsagePath -Append
                } else {
                    $org_task_usages | Export-Csv -NoTypeInformation -Path $orgTaskUsagePath
                }
            }
            finally {
                if($lockTaken) { [System.Threading.Monitor]::Exit($taskLock) }
            }
        }

        # Org Service Usage
        $orgServiceReport = Invoke-RestMethod "https://app-usage.$system_domain/organizations/$($org.metadata.guid)/service_usages?start=$startDate&end=$endDate" -Headers @{Authorization="$token"}
        $org_service_usages = ($orgServiceReport.service_usages | select-object @{Name="deleted"; Expression={$_.deleted}},
            @{Name="duration_in_seconds"; Expression={$_.duration_in_seconds}},
            @{Name="space_guid"; Expression={$_.space_guid}},
            @{Name="space_name"; Expression={$_.space_name}},
            @{Name="service_instance_guid"; Expression={$_.service_instance_guid}},
            @{Name="service_instance_name"; Expression={$_.service_instance_name}},
            @{Name="service_instance_type"; Expression={$_.service_instance_type}},
            @{Name="service_plan_guid"; Expression={$_.service_plan_guid}},
            @{Name="service_plan_name"; Expression={$_.service_plan_name}},
            @{Name="service_name"; Expression={$_.service_name}},
            @{Name="service_guid"; Expression={$_.service_guid}},
            @{Name="service_instance_creation"; Expression={$_.service_instance_creation}},
            @{Name="service_instance_deletion"; Expression={$_.service_instance_deletion}},
            @{Name="organization_name"; Expression={$org.entity.name}},
            @{Name="organization_guid"; Expression={$orgServiceReport.organization_guid}},
            @{Name="period_start"; Expression={$orgServiceReport.period_start}},
            @{Name="period_end"; Expression={$orgServiceReport.period_end}},
            @{Name="platform"; Expression={$platform}}
        )
        if($org_service_usages.Count -gt 0) {
            $orgServiceUsagePath = Join-Path $path "org-service-usage.csv"
            [bool]$lockTaken = $false
            try {
                [System.Threading.Monitor]::Enter($serviceLock)
                $lockTaken = $true
                if(Test-Path $orgServiceUsagePath -PathType Leaf) {
                    $org_service_usages | Export-Csv -NoTypeInformation -Path $orgServiceUsagePath -Append
                } else {
                    $org_service_usages | Export-Csv -NoTypeInformation -Path $orgServiceUsagePath
                }
            }
            finally {
                if($lockTaken) { [System.Threading.Monitor]::Exit($serviceLock) }
            }
        }
        $startDateTime = $startDateTime.AddMonths(1)
        $endDateTime = $endDateTime.AddMonths(2)
        $endDateTime = $endDateTime.AddDays(-$endDateTime.Day)
    }
}

foreach($key in $targets.Keys) 
{
    # Target and authenticate
    & cf api "api.$($targets[$key])" --skip-ssl-validation
    & cf.exe auth $creds.UserName "$([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($creds.Password)))"

    if($?)
    {
        $system_domain = $targets[$key]
        # Platform App Usage
        Export-PlatformUsage -SysDomain $system_domain -Type "app_usages" -Path "summary-app-usage.csv" -Platform $key

        # Platform Task Usage
        Export-PlatformUsage -SysDomain $system_domain -Type "task_usages" -Path "summary-task-usage.csv" -Platform $key

        # Platform Service Usage
        $platformServiceReport = Invoke-RestMethod "https://app-usage.$system_domain/system_report/service_usages" -Headers @{Authorization="$(cf oauth-token)"}
        if($?) {
            [System.Collections.ArrayList]$service_usages = @()
            foreach($monthly_service_report in $platformServiceReport.monthly_service_reports) {
                foreach($usage_data in $monthly_service_report.usages) {
                    $service_usages += ($usage_data | select-object @{Name="month"; Expression={$_.month}},
                        @{Name="year"; Expression={$_.year}},
                        @{Name="duration_in_hours"; Expression={$_.duration_in_hours}},
                        @{Name="average_instances"; Expression={$_.average_instances}},
                        @{Name="maximum_instances"; Expression={$_.maximum_instances}},
                        @{Name="report_time"; Expression={$platformServiceReport.report_time}},
                        @{Name="service_name"; Expression={$monthly_service_report.service_name}},
                        @{Name="service_guid"; Expression={$monthly_service_report.service_guid}},
                        @{Name="platform"; Expression={$key}}
                    )
                }
            }
            $serviceSummaryPath = "summary-service-usage.csv"
            if(Test-Path $serviceSummaryPath -PathType Leaf) {
                $service_usages | Export-CSV -NoTypeInformation -Path $serviceSummaryPath -Append
            } else {
                $service_usages | Export-CSV -NoTypeInformation -Path $serviceSummaryPath 
            }

            # All the Orgs we can see
            $orgs = & cf curl "/v2/organizations" | ConvertFrom-Json

            if($?) {
                $token = "$(cf oauth-token)"
                $jobs = @()
                $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 8, $sessionState, $Host)
                $runspacePool.Open()

                foreach($org in $orgs.resources) {
                    if($org.entity.name -ne "system") {
                        $job = [powershell]::Create().AddScript($OrgScript)
                        [void]$job.AddParameter("platform", $key)
                        [void]$job.AddParameter("org", $org)
                        [void]$job.AddParameter("system_domain", $system_domain)
                        [void]$job.AddParameter("token", $token)
                        [void]$job.AddParameter("environment", $key)
                        [void]$job.AddParameter("path", $PSScriptRoot)
                        [void]$job.AddParameter("appLock", $syncOrgAppUsage)
                        [void]$job.AddParameter("taskLock", $syncOrgTaskUsage)
                        [void]$job.AddParameter("serviceLock", $syncOrgServiceUsage)
                        $job.RunspacePool = $runspacePool
                        $jobs += New-Object PSObject -Property @{
                            Job = $job
                            Result = $job.BeginInvoke()
                        }
                    }
                }

                Write-Host "Waiting for jobs to complete" -NoNewline
                while( $jobs.Result.IsCompleted -contains $false )
                {
                    Write-Host "." -NoNewline
                    Start-Sleep -Seconds 2
                }
                Write-Host "Done!"
            }
        }
    }
}