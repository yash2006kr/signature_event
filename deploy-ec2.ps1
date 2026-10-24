param(
    [string]$Profile = "signature-event",
    [string]$Region = "ap-southeast-2",
    [string]$DistPath = ".\dist"
)

$ErrorActionPreference = "Stop"
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","User") + ";" + [System.Environment]::GetEnvironmentVariable("Path","Machine")

Write-Host "🚀 Starting EC2 Deployment for Blueprint to Live..." -ForegroundColor Cyan

# 1. Verify dist folder
if (-not (Test-Path $DistPath)) {
    Write-Host "Creating dist folder since it doesn't exist..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $DistPath -Force | Out-Null
    if (-not (Test-Path "$DistPath\index.html")) {
        Set-Content -Path "$DistPath\index.html" -Value "<h1>Blueprint to Live - Static UI</h1>"
    }
}

# 2. Get Default VPC
Write-Host "🔍 Locating Default VPC..." -ForegroundColor Cyan
$vpcId = (aws ec2 describe-vpcs --region $Region --profile $Profile --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
if (-not $vpcId -or $vpcId -eq "None") {
    $vpcId = (aws ec2 describe-vpcs --region $Region --profile $Profile --query "Vpcs[0].VpcId" --output text)
}
Write-Host "Using VPC: $vpcId" -ForegroundColor Green

# 3. Create or get Security Group
$sgName = "blueprint-live-sg"
$sgId = (aws ec2 describe-security-groups --region $Region --profile $Profile --filters "Name=group-name,Values=$sgName" "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[0].GroupId" --output text)

if (-not $sgId -or $sgId -eq "None") {
    Write-Host "🛡️ Creating Security Group '$sgName'..." -ForegroundColor Cyan
    $sgId = (aws ec2 create-security-group --group-name $sgName --description "Security group for Blueprint to Live web server" --vpc-id $vpcId --region $Region --profile $Profile --query "GroupId" --output text)
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $Region --profile $Profile | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $Region --profile $Profile | Out-Null
}
Write-Host "Using Security Group: $sgId - Ports 80 and 22 open" -ForegroundColor Green

# 4. Get Latest Amazon Linux 2023 AMI
Write-Host "🔍 Finding latest Amazon Linux 2023 AMI..." -ForegroundColor Cyan
$amiId = (aws ssm get-parameters --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" --region $Region --profile $Profile --query "Parameters[0].Value" --output text)
Write-Host "Using AMI: $amiId" -ForegroundColor Green

# 5. Build UserData script using GitHub Repo
$userDataScript = @"
#!/bin/bash
dnf update -y
dnf install -y nginx git
systemctl enable nginx
systemctl start nginx

mkdir -p /tmp/repo
git clone https://github.com/yash2006kr/signature_event.git /tmp/repo
cp -r /tmp/repo/dist/* /usr/share/nginx/html/
chown -R nginx:nginx /usr/share/nginx/html
chmod -R 755 /usr/share/nginx/html
systemctl restart nginx
"@

$userDataBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userDataScript))

# 7. Launch Instance
Write-Host "⚡ Launching EC2 instance (t3.micro)..." -ForegroundColor Cyan
$instanceId = (aws ec2 run-instances `
    --image-id $amiId `
    --instance-type t3.micro `
    --security-group-ids $sgId `
    --user-data $userDataBase64 `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=Blueprint-Live-Server}]" `
    --region $Region `
    --profile $Profile `
    --query "Instances[0].InstanceId" `
    --output text)

Write-Host "Instance Launched: $instanceId" -ForegroundColor Green
Write-Host "⏳ Waiting for public IP allocation..." -ForegroundColor Yellow

$publicIp = "None"
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 3
    $publicIp = (aws ec2 describe-instances --instance-ids $instanceId --region $Region --profile $Profile --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    if ($publicIp -and $publicIp -ne "None") {
        break
    }
}

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host "🎉 DEPLOYMENT READY!" -ForegroundColor Green
Write-Host "Instance ID : $instanceId" -ForegroundColor White
Write-Host "Public IP   : $publicIp" -ForegroundColor White
Write-Host "Live URL    : http://$publicIp" -ForegroundColor Yellow
Write-Host "=======================================================`n" -ForegroundColor Green
