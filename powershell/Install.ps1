<#

Creates required buckets, uploads files and launches TRANSIT-VPC and PA-SUBSCRIBER CloudFormation templates.

Prerequisites

EC2 instance running Windows Server 2016 using IAM Role with these permissions:

    AdministratorAccess
    AWSLambdaENIManagementAccess

Login to Windows server, open PowerShell windows, clone the repository and run with:

    & .\powershell\Install.PS1

Login Example

ssh -i MY_SSH_KEY_NAME -l ec2-user NAT_REMOTE_IP -L 4001:10.100.0.90:22 -L 4000:10.100.0.90:443  -nNtv
ssh -i MY_SSH_KEY_NAME -l admin localhost -p 4001

#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Error.Clear()
clear

if (!(Test-Path cfts))
{
    Write-Error "Cannot find cfts"
}
if (!(Get-Command New-S3Bucket -ErrorAction Ignore))
{
    Import-Module AWSPowerShell
}

# BEGIN CONFIGURATION

$awsAccount = (Get-STSCallerIdentity).Account
$sshKey = "MY_SSH_KEY_NAME"
$myip = (New-Object System.Net.WebClient).DownloadString("http://ipecho.net/plain")
$trustedSource = "$myip/32"
#$LaunchSubscriberVpc = "No";
$LaunchSubscriberVpc = "Yes";

$region = "us-west-2"
Set-DefaultAWSRegion $region
$az1 = "$($region)b"
$az2 = "$($region)c"

$username = "admin"
$password = "ReanCloud123!"
$groupCapacity = "6"
$transitStackName = "TRANSIT-VPC"
$subscriberInitStackName = "PA-SUBSCRIBER"
$aws_pa_cfn = "aws-pa-cfn-$awsAccount"
$aws_pa_config = "aws-pa-config-$awsAccount"
$aws_pa_lambda = "aws-pa-lambda-$awsAccount"
$aws_pa_vpn = "aws-pa-vpn-$awsAccount"
$aws_pa_subscriber = "aws-pa-subscriber-$awsAccount"
$aws_pa_subscriber_ct = "aws-pa-subscriber-ct-$awsAccount"

# END CONFIGURATION

function Create-Bucket ($BucketName)
{
    if (!(Get-S3Bucket -BucketName $BucketName))
    {
        New-S3Bucket -BucketName $BucketName
    }
}
function WriteFile ($BucketName, $FilePath, $Prefix = "")
{
    $fn = Split-Path -Path $FilePath -Leaf
    Write-S3Object -BucketName $BucketName -Key ($Prefix + $fn) -File $FilePath
}
function Get-S3Url ($BucketName, $Key)
{
    $url = Get-S3PreSignedURL -BucketName $BucketName -Key $Key -Expire ([DateTime]::Now)
    Return $url.Substring(0, $url.IndexOf("?"))
}
function Get-CfnParameters ([hashtable]$HashTable, $AddTo = @( ))
{
    foreach ($key in $HashTable.Keys)
    {
        $p1 = new-object Amazon.CloudFormation.Model.Parameter
        $p1.ParameterKey = $key
        $p1.ParameterValue = $HashTable[$key]
        $AddTo += $p1
    }
    return $AddTo
}
function Get-CfnStackExists ($StackName)
{
    try 
    {
        return Get-CFNStack -StackName $StackName
    }
    catch
    {
        $error.RemoveAt(0)
        return $null
    }
}
function Wait-CfnStackComplete ($stack)
{
    $stackName = $stack.StackName
    do
    {
        $stack2 = Get-CFNStack $stackName
        $status = $stack2.StackStatus
        $done = $status -eq "CREATE_COMPLETE"
        if (!$done)
        {
            if ($status -ne "CREATE_IN_PROGRESS")
            {
                Write-Error $status
            }
            sleep 3
        }
    } while(!$done)
}
function Clean-S3Bucket ($BucketName)
{
    $files = Get-S3Object -BucketName $BucketName

    foreach ($file in $files)
    {
        Remove-S3Object -BucketName $BucketName -Key $file.Key -Force
    }
}
function New-S3Folder ($BucketName, $FolderName)
{
    # According to logs, the Palo Alto bootstrapper checks for both of these (with and without the traingin slash).
    # This first one results in a "folder" when viewed from the AWS Console
    Write-S3Object -BucketName $BucketName -Key "$FolderName/" -File .\zero
    # This one seems to be needed to have the bootstrapper work but results in an extra object when viewed from the console.
    Write-S3Object -BucketName $BucketName -Key "$FolderName" -File .\zero
}
if ($false)
{
    # Change to true to clean out buckets and delete all log groups
    Clean-S3Bucket  -BucketName $aws_pa_cfn 
    Clean-S3Bucket  -BucketName $aws_pa_config
    Clean-S3Bucket  -BucketName $aws_pa_lambda
    Clean-S3Bucket  -BucketName $aws_pa_subscriber

    $groups = Get-CWLLogGroups | where { $_.LogGroupName.Contains($transitStackName) -or $_.LogGroupName.Contains($subscriberInitStackName) }
    foreach ($group in $groups)
    {
        Remove-CWLLogGroup -LogGroupName $group.LogGroupName -Force
    }
    Write-Error "Cleanup Complete" #Stop the script
}
Create-Bucket $aws_pa_cfn
Create-Bucket $aws_pa_config
Create-Bucket $aws_pa_lambda
Create-Bucket $aws_pa_subscriber

$transitStack = Get-CfnStackExists $transitStackName
if (!$transitStack)
{
    $templateName = "initializeTransitAccount.json"
    WriteFile $aws_pa_cfn .\cfts\$templateName
    $templateUrl = Get-S3Url -BucketName $aws_pa_cfn -Key $templateName

    Set-Content -Path .\zero -Value @( )
    New-S3Folder -BucketName $aws_pa_config -FolderName "config"
    New-S3Folder -BucketName $aws_pa_config -FolderName "content"
    New-S3Folder -BucketName $aws_pa_config -FolderName "license"
    New-S3Folder -BucketName $aws_pa_config -FolderName "software"
    WriteFile -BucketName $aws_pa_config -FilePath .\prerequisites\bootstrap\config\bootstrap.xml -Prefix "config/"
    WriteFile -BucketName $aws_pa_config -FilePath .\prerequisites\bootstrap\config\init-cfg.txt -Prefix "config/"
    WriteFile -BucketName $aws_pa_lambda -FilePath .\prerequisites\lambda.zip
    WriteFile -BucketName $aws_pa_lambda -FilePath .\cfts\paGroupCft.json

    $url = Get-S3Url -BucketName $aws_pa_lambda -Key paGroupCft.json
    $parms = Get-CfnParameters @{ 
        PaGroupTemplateUrl = $url; #2
        DeLicenseApiKey = ""; #3
        UserName = $username; #4
        Password = $password; #5
        paBootstrapBucketName = $aws_pa_config; #6
        LambdaFunctionsBucketName = $aws_pa_lambda; #7
        VpnConfigBucketName = $aws_pa_vpn; #8
        sshKey = $sshKey; #9
        az1 = $az1; #10
        az2 = $az2; #10
        SubscriberAWSAccountNumber = $awsAccount; #11
        PaloAltoGroupCapacity = $groupCapacity; #12
        #LambdaZipFile = ""; #13
        #transitVpcCidr = ""; #14
        #dmzAz1Cidr = "";  #15
        #dmzAz2Cidr = "";  #15
        #pdmzAz1Cidr = ""; #15
        #pdmzAz2Cidr = ""; #15
        #mgmtAz1Cidr = ""; #15
        #mgmtAz2Cidr = ""; #15
        trustedSource = $trustedSource; #16
        #NatInstanceType = ""; #17
    }
    $stackId = New-CFNStack -StackName $transitStackName -TemplateURL $templateUrl -Parameters $parms -Capabilities CAPABILITY_NAMED_IAM
    $transitStack = Get-CFNStack $stackId
}
Wait-CfnStackComplete $transitStack

$subStack = Get-CfnStackExists $subscriberInitStackName
if (!$subStack)
{
    # Get transit stack again, now with outputs
    $transitStack = Get-CfnStackExists $transitStackName
    $transitSnsArn = ($transitStack.Outputs | where { $_.OutputKey -eq "TransitSnsArn" }).OutputValue
    $transitAssumeRoleArn = ($transitStack.Outputs | where { $_.OutputKey -eq "TransitAssumeRoleArn" }).OutputValue

    $templateName = "initializeSubscriberAccount.json"
    WriteFile $aws_pa_cfn .\cfts\$templateName
    $templateUrl = Get-S3Url -BucketName $aws_pa_cfn -Key $templateName

    WriteFile -BucketName $aws_pa_subscriber -FilePath .\prerequisites\lambda.zip
    WriteFile -BucketName $aws_pa_subscriber -FilePath .\cfts\subscriberVpcCft.json

    $url = Get-S3Url -BucketName $aws_pa_subscriber -Key paGroupCft.json
    $parms = Get-CfnParameters @{ 
        TransitSNSTopicArn= $transitSnsArn; #2
        TransitAssumeRoleArn= $transitAssumeRoleArn; #3
        TransitAWSAccountNumber= $awsAccount; #4
        LambdaFunctionsBucketName= $aws_pa_subscriber; #5
        CloudTrailS3BucketName= $aws_pa_subscriber_ct; #6
        SshKey = $sshKey; #7
        az1 = $az1; #8
        az2 = $az2; #8
        LaunchSubscriberVpc= $LaunchSubscriberVpc; #9
        #LambdaZipFile= ""; #10
        VpcCidrRange = "10.10.0.0/16"; #11
        SubnetCidr1 = "10.10.0.0/24"; #12
        SubnetCidr2 = "10.10.1.0/24"; #12
        SubnetCidr3 = "10.10.2.0/24"; #12
        SubnetCidr4 = "10.10.3.0/24"; #12
        trustedSource = $trustedSource; #13
    }
    $stackId = New-CFNStack -StackName $subscriberInitStackName -TemplateURL $templateUrl -Parameters $parms -Capabilities CAPABILITY_NAMED_IAM
    $subStack = Get-CFNStack $stackId
}

Wait-CfnStackComplete $subStack

