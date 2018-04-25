# GetAccountingReports
Extract the usage stats from a list of Pivotal Application Service foundations

## Desription
This project contains a PowerShell script to extract data from the Pivotal "Usage-Service" per the guidance at https://docs.pivotal.io/pivotalcf/1-11/opsguide/accounting-report.html.  This script should work with Pivotal Application Service (formerly known as Pivotal Elastic Runtime) from v1.11 and onward.

The script produces up to 6 files:
* __summary-app-usage.csv__ - The summarized Application Usage data for all the foundations reported against.
* __summary-task-usage.csv__ - The summarized Task Usage data for all the foundations reported against.
* __summary-service-usage.csv__ - The summarized Service Usage data for all the foundations reported against.
* __org-app-usage.csv__ - Application Usage data broken out by organization, space, and application for all foundations reported against.
* __org-task-usage.csv__ - Task Usage data broken out by organization, space, and parent application for all foundations reported against.
* __org-service-usage.csv__ - Service Usage data broken out by organization, space, and service instance for all foundations reported against.

## Usage
1. Clone or Download this repo
2. Copy the "environments-example.txt" file to a file called "environments.txt"
3. Edit the "environments.txt" file to contain all the foundations with their system domains that you want to report on.
4. Open Powershell and change directories to where you downloaded or cloned this repo to.
5. Execute `.\Download-Usage.ps1` and enter the username and password of a user that has the `usage_service.audit` scope and access to all the orgs you want to report on (or cloud_controller.admin_read_only).  Also, a platform admin account will work here.
6. Wait for the script to complete.  The time it takes will depend on you network, infrastructure, and the number of foundations you are reporting against.
