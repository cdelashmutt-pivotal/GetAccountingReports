# List of Environments keyed by name, and the value is the system domain
$targets = ConvertFrom-StringData ([io.file]::ReadAllText("environments.txt"))

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
        for($i=0; $i -lt $platformReport.monthly_reports.Length; $i++) { 
            $platformReport.monthly_reports[$i] | Add-Member -Name "report_time" -Value $platformReport.report_time -MemberType NoteProperty
            $platformReport.monthly_reports[$i] | Add-Member -Name "platform" -Value $Platform -MemberType NoteProperty
        }
        if(Test-Path $Path -PathType Leaf) {
            $platformReport.monthly_reports | Export-CSV -NoTypeInformation -Path "$Path" -Append
        } else {
            $platformReport.monthly_reports | Export-CSV -NoTypeInformation -Path "$Path"
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
        [System.Collections.ArrayList]$org_app_usages = @()
        $orgAppReport = Invoke-RestMethod "https://app-usage.$system_domain/organizations/$($org.metadata.guid)/app_usages?start=$startDate&end=$endDate" -Headers @{Authorization="$token"}
        foreach($orgAppUsage in $orgAppReport.app_usages) {
            $orgAppUsage | Add-Member -Name "organization_name" -Value $org.entity.name -MemberType NoteProperty 
            $orgAppUsage | Add-Member -Name "organization_guid" -Value $orgAppReport.organization_guid -MemberType NoteProperty 
            $orgAppUsage | Add-Member -Name "period_start" -Value $orgAppReport.period_start -MemberType NoteProperty 
            $orgAppUsage | Add-Member -Name "period_end" -Value $orgAppReport.period_end -MemberType NoteProperty 
            $orgAppUsage | Add-Member -Name "platform" -Value $platform -MemberType NoteProperty 
            [void]$org_app_usages.Add($orgAppUsage)
        }
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
                    $task_summary | Add-Member -Name "organization_name" -Value $org.entity.name -MemberType NoteProperty 
                    $task_summary | Add-Member -Name "organization_guid" -Value $orgTaskReport.organization_guid -MemberType NoteProperty 
                    $task_summary | Add-Member -Name "period_start" -Value $orgTaskReport.period_start -MemberType NoteProperty 
                    $task_summary | Add-Member -Name "period_end" -Value $orgTaskReport.period_end -MemberType NoteProperty
                    $task_summary | Add-Member -Name "space_name" -Value $space_summary.Value.space_name -MemberType NoteProperty
                    $task_summary | Add-Member -Name "space_guid" -Value $space_summary.Name -MemberType NoteProperty
                    $task_summary | Add-Member -Name "platform" -Value $platform -MemberType NoteProperty
                    [void]$org_task_usages.Add($task_summary)
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
        [System.Collections.ArrayList]$org_service_usages = @()
        $orgServiceReport = Invoke-RestMethod "https://app-usage.$system_domain/organizations/$($org.metadata.guid)/service_usages?start=$startDate&end=$endDate" -Headers @{Authorization="$token"}
        foreach($service_usage in $orgServiceReport.service_usages) {
            $service_usage | Add-Member -Name "organization_name" -Value $org.entity.name -MemberType NoteProperty 
            $service_usage | Add-Member -Name "organization_guid" -Value $orgServiceReport.organization_guid -MemberType NoteProperty 
            $service_usage | Add-Member -Name "period_start" -Value $orgServiceReport.period_start -MemberType NoteProperty 
            $service_usage | Add-Member -Name "period_end" -Value $orgServiceReport.period_end -MemberType NoteProperty
            $service_usage | Add-Member -Name "platform" -Value $platform -MemberType NoteProperty
            [void]$org_service_usages.Add($service_usage)
        }
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
                foreach($usage in $monthly_service_report.usages) {
                    $usage | Add-Member -Name "report_time" -Value $platformServiceReport.report_time -MemberType NoteProperty 
                    $usage | Add-Member -Name "service_name" -Value $monthly_service_report.service_name -MemberType NoteProperty 
                    $usage | Add-Member -Name "service_guid" -Value $monthly_service_report.service_guid -MemberType NoteProperty
                    $usage | Add-Member -Name "platform" -Value $key -MemberType NoteProperty
                    [void]$service_usages.Add( $usage )
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