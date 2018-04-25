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


function Export-PlatformUsage ([string]$SysDomain, [string]$Type, [string]$Path) {
    $platformReport = Invoke-RestMethod "https://app-usage.$SysDomain/system_report/$Type" -Headers @{Authorization="$(cf oauth-token)"}
    if($?) {
        for($i=0; $i -lt $platformReport.monthly_reports.Length; $i++) { 
            $platformReport.monthly_reports[$i] | Add-Member -Name "report_time" -Value $platformReport.report_time -MemberType NoteProperty
        }
        $platformReport.monthly_reports | Export-CSV -NoTypeInformation -Path "$Path"
    }
}

$creds = Get-Credential -Message "Enter your FEAD Shortname and Password"
if(!$creds){ exit }

$OrgScript = {
    Param (
        $org,
        [string]$system_domain,
        [string]$token,
        [string]$environment,
        [string]$path
    )
    $startDate = ([DateTime]$org.metadata.created_at).ToString("yyyy-MM-dd")
    $endDate = [DateTime]::Now.ToString("yyyy-MM-dd")
    # Org App Usage
    [System.Collections.ArrayList]$org_app_usages = @()
    $orgAppReport = Invoke-RestMethod "https://app-usage.$system_domain/organizations/$($org.metadata.guid)/app_usages?start=$startDate&end=$endDate" -Headers @{Authorization="$token"}
    foreach($orgAppUsage in $orgAppReport.app_usages) {
        $orgAppUsage | Add-Member -Name "organization_name" -Value $org.entity.name -MemberType NoteProperty 
        $orgAppUsage | Add-Member -Name "organization_guid" -Value $orgAppReport.organization_guid -MemberType NoteProperty 
        $orgAppUsage | Add-Member -Name "period_start" -Value $orgAppReport.period_start -MemberType NoteProperty 
        $orgAppUsage | Add-Member -Name "period_end" -Value $orgAppReport.period_end -MemberType NoteProperty 
        [void]$org_app_usages.Add($orgAppUsage)
    }
    if($org_app_usages.Count -gt 0) {
        $org_app_usages | Export-Csv -NoTypeInformation -Path $(Join-Path $path "$environment-$($org.entity.name)-app-usage.csv")
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
        Export-PlatformUsage -SysDomain $system_domain -Type "app_usages" -Path "$($key)-platform-app-usage.csv"

        # Platform Task Usage
        Export-PlatformUsage -SysDomain $system_domain -Type "task_usages" -Path "$($key)-platform-task-usage.csv"

        # Platform Service Usage
        $platformServiceReport = Invoke-RestMethod "https://app-usage.$system_domain/system_report/service_usages" -Headers @{Authorization="$(cf oauth-token)"}
        if($?) {
            [System.Collections.ArrayList]$service_usages = @()
            foreach($monthly_service_report in $platformServiceReport.monthly_service_reports) {
                foreach($usage in $monthly_service_report.usages) {
                    $usage | Add-Member -Name "report_time" -Value $platformServiceReport.report_time -MemberType NoteProperty 
                    $usage | Add-Member -Name "service_name" -Value $monthly_service_report.service_name -MemberType NoteProperty 
                    $usage | Add-Member -Name "service_guid" -Value $monthly_service_report.service_guid -MemberType NoteProperty
                    [void]$service_usages.Add( $usage )
                }
            }
            $service_usages | Export-CSV -NoTypeInformation -Path "$($key)-platform-service-usage.csv"

            # All the Orgs we can see
            $orgs = & cf curl "/v2/organizations" | ConvertFrom-Json

            if($?) {
                $token = "$(cf oauth-token)"
                $jobs = @()
                $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 16, $sessionState, $Host)
                $runspacePool.Open()

                foreach($org in $orgs.resources) {
                    if($org.entity.name -ne "system") {
                        $job = [powershell]::Create().AddScript($OrgScript)
                        [void]$job.AddParameter("org", $org)
                        [void]$job.AddParameter("system_domain", $system_domain)
                        [void]$job.AddParameter("token", $token)
                        [void]$job.AddParameter("environment", $key)
                        [void]$job.AddParameter("path", $PSScriptRoot)
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