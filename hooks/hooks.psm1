$ErrorActionPreference = 'Stop'

try {
    $charmHelpersPath = Join-Path (Split-Path $PSScriptRoot) "lib\Modules\CharmHelpers"
    Import-Module -Force -DisableNameChecking $charmHelpersPath
} catch {
    juju-log.exe "ERROR while loading PowerShell charm helpers: $_"
    exit 1
}

$NEUTRON_GIT           = "https://github.com/openstack/neutron.git"
$NOVA_GIT              = "https://github.com/openstack/nova.git"
$NETWORKING_HYPERV_GIT = "https://github.com/stackforge/networking-hyperv.git"

$OPENSTACK_DIR = Join-Path $env:SystemDrive "OpenStack"
$PYTHON_DIR    = Join-Path $env:SystemDrive "Python27"
$LIB_DIR       = Join-Path $PYTHON_DIR "lib\site-packages"
$BUILD_DIR     = Join-Path $OPENSTACK_DIR "build"
$INSTANCES_DIR = Join-Path $OPENSTACK_DIR "Instances"
$BIN_DIR       = Join-Path $OPENSTACK_DIR "bin"
$CONFIG_DIR    = Join-Path $OPENSTACK_DIR "etc"
$LOG_DIR       = Join-Path $OPENSTACK_DIR "log"
$SERVICE_DIR   = Join-Path $OPENSTACK_DIR "service"
$FILES_DIR     = Join-Path ${env:CHARM_DIR} "files"

$NOVA_SERVICE_NAME        = "nova-compute"
$NOVA_SERVICE_DESCRIPTION = "OpenStack nova Compute Service"
$NOVA_SERVICE_EXECUTABLE  = Join-Path $PYTHON_DIR "Scripts\nova-compute.exe"
$NOVA_SERVICE_CONFIG      = Join-Path $CONFIG_DIR "nova.conf"

$NEUTRON_SERVICE_NAME        = "neutron-hyperv-agent"
$NEUTRON_SERVICE_DESCRIPTION = "OpenStack Neutron Hyper-V Agent Service"
$NEUTRON_SERVICE_EXECUTABLE  = Join-Path $PYTHON_DIR "Scripts\neutron-hyperv-agent.exe"
$NEUTRON_SERVICE_CONFIG      = Join-Path $CONFIG_DIR "neutron_hyperv_agent.conf"

$PYTHON_PROCESS_NAME = "python"

$VALID_HASHING_ALGORITHMS = @('SHA1', 'SHA256', 'SHA384', 'SHA512',
                              'MACTripleDES', 'MD5', 'RIPEMD160')


function Get-TemplatesDir {
    return (Join-Path (Get-JujuCharmDir) "templates")
}


function Unzip-With7z {
    Param(
        [string]$ZipPath,
        [string]$DestinationFolder
    )

    Execute-ExternalCommand -Command { 7z.exe x -y $ZipPath -o"$DestinationFolder" } `
                            -ErrorMessage "Failed to unzip $ZipPath."
}


function Get-ADContext {
    $ctx =  @{
        "ad_host"        = "private-address";
        "ip_address"     = "address";
        "ad_hostname"    = "hostname";
        "ad_username"    = "username";
        "ad_password"    = "password";
        "ad_domain"      = "domainName";
        "ad_credentials" = "adcredentials";
    }
    return (Get-JujuRelationParams 'ad-join' $ctx)
}


function Get-DevStackContext {
    $ctx =  @{
        "devstack_ip"       = "devstack_ip";
        "devstack_password" = "password";
        "rabbit_user"       = "rabbit_user";
    }
    return (Get-JujuRelationParams 'devstack' $ctx)
}


# Returns an HashTable with the download URL, the checksum (with the hashing
# algorithm) for a specific package. The URL config option for that package
# is parsed. In case the checksum is not specified, 'CHECKSUM' and
# 'HASHING_ALGORITHM' fields will be $null.
function Get-URLChecksum {
    Param(
        [string]$URLConfigKey
    )

    $url = Get-JujuCharmConfig -scope $URLConfigKey
    if ($url.contains('#')) {
        $urlSplit = $url.split('#')
        $algorithm = $urlSplit[1]
        if (!$algorithm.contains('=')) {
            Throw ("Invalid algorithm format! " +
                   "Use the format: <hashing_algorithm>=<checksum>")
        }

        $algorithmSplit = $algorithm.split('=')
        $hashingAlgorithm = $algorithmSplit[0]
        if ($hashingAlgorithm -notin $VALID_HASHING_ALGORITHMS) {
            Throw ("Invalid hashing algorithm format! " +
                   "Valid formats are: " + $VALID_HASHING_ALGORITHMS)
        }

        $checksum = $algorithmSplit[1]
        return @{ 'URL' = $urlSplit[0];
                  'CHECKSUM' = $checksum;
                  'HASHING_ALGORITHM' = $hashingAlgorithm }
    }

    return @{ 'URL' = $url;
              'CHECKSUM' = $null;
              'HASHING_ALGORITHM' = $null }
}


function Check-FileIntegrity {
    Param(
        [string]$FilePath,
        [ValidateScript({$_ -in $VALID_HASHING_ALGORITHMS})]
        [string]$Algorithm,
        [string]$Checksum
    )

    $hash = (Get-FileHash -Path $FilePath -Algorithm $Algorithm).Hash
    if ($hash -eq $Checksum) {
        return $true
    }
    return $false
}


# Returns the full path of the package after it is downloaded using
# the URL parameter (a checksum may optionally be specified). The
# package is cached on the disk until the installation successfully finishes.
# If the hook fails, on the second run this function will return the cached
# package path if checksum is given and it matches.
function Get-PackagePath {
    Param(
        [string]$URL,
        [string]$Checksum="",
        [string]$HashingAlgorithm=""
    )

    $packagePath = Join-Path $env:TEMP $URL.Split('/')[-1]
    if (Test-Path $packagePath) {
        if ($Checksum -and $HashingAlgorithm) {
            if (Check-FileIntegrity $packagePath $HashingAlgorithm $Checksum) {
                return $packagePath
            }
        }
        Remove-Item -Recurse -Force -Path $packagePath
    }

    $packagePath = Download-File -DownloadLink $URL -DestinationFile $packagePath
    if ($Checksum -and $HashingAlgorithm) {
        if (!(Check-FileIntegrity $packagePath $HashingAlgorithm $Checksum)) {
            Throw "Wrong $HashingAlgorithm checksum for $URL"
        }
    }
    return $packagePath
}


# Installs a package after it is downloaded from the Internet and checked for
# integrity with SHA1 checksum. Accepts as parameters: an URL, an optional
# 'Checksum' with its 'HashingAlgorithm' and 'ArgumentList' which can be passed
# if the installer requires unattended installation.
# Supported packages formats are: '.exe' and '.msi'
function Install-Package {
    Param(
        [string]$URL,
        [string]$Checksum="",
        [string]$HashingAlgorithm="",
        [array]$ArgumentList
    )

    Write-JujuLog "Installing package $URL..."

    $packageFormat = $URL.Split('.')[-1]
    $acceptedFormats = @('msi', 'exe')
    if ($packageFormat -notin $acceptedFormats) {
        Throw ("Cannot install the package found at this URL: $URL " +
               "Unsupported installer format.")
    }

    $installerPath = Get-PackagePath $URL $Checksum $HashingAlgorithm
    $stat = Start-Process -FilePath $installerPath -ArgumentList $ArgumentList `
                          -PassThru -Wait
    if ($stat.ExitCode -ne 0) {
        throw "Package failed to install."
    }
    Remove-Item $installerPath

    Write-JujuLog "Finished installing package."
}


function Run-GitClonePull {
    Param(
        [string]$Path,
        [string]$URL,
        [string]$Branch="master"
    )

    if (!(Test-Path -Path $Path)) {
        ExecuteWith-Retry {
            Execute-ExternalCommand -Command { git clone $URL $Path } `
                                    -ErrorMessage "Git clone failed"
        }
        Execute-ExternalCommand -Command { git checkout $Branch } `
                                -ErrorMessage "Git checkout failed"
    } else {
        pushd $Path
        try {
            $gitPath = Join-Path $Path ".git"
            if (!(Test-Path -Path $gitPath)) {
                Remove-Item -Recurse -Force *
                ExecuteWith-Retry {
                    Execute-ExternalCommand -Command { git clone $URL $Path } `
                                            -ErrorMessage "Git clone failed"
                }
            } else {
                ExecuteWith-Retry {
                    Execute-ExternalCommand -Command { git fetch --all } `
                                            -ErrorMessage "Git fetch failed"
                }
            }
            ExecuteWith-Retry {
                Execute-ExternalCommand -Command { git checkout $Branch } `
                                        -ErrorMessage "Git checkout failed"
            }
            Get-ChildItem . -Include *.pyc -Recurse | foreach ($_) { Remove-Item $_.fullname }
            Execute-ExternalCommand -Command { git reset --hard } `
                                    -ErrorMessage "Git reset failed"
            Execute-ExternalCommand -Command { git clean -f -d } `
                                    -ErrorMessage "Git clean failed"
            ExecuteWith-Retry {
                Execute-ExternalCommand -Command { git pull } `
                                        -ErrorMessage "Git pull failed"
            }
        } finally {
            popd
        }
    }
}


function Install-OpenStackProjectFromRepo {
    Param(
        [string]$ProjectPath
    )

#    $requirements = Join-Path $ProjectPath "requirements.txt"
#    if((test-path $requirements)){
#        Execute-ExternalCommand -Command { pip install -r $requirements } `
#                            -ErrorMessage "Failed to install requirements from $ProjectPath."
#    }
    Execute-ExternalCommand -Command { pip install -e $ProjectPath } `
                            -ErrorMessage "Failed to install $ProjectPath from repo."
    popd
}


function Run-GerritGitPrep {
    Param(
        [Parameter(Mandatory=$True)]
        [string]$ZuulUrl,
        [Parameter(Mandatory=$True)]
        [string]$GerritSite,
        [Parameter(Mandatory=$True)]
        [string]$ZuulRef,
        [Parameter(Mandatory=$True)]
        [string]$ZuulChange,
        [Parameter(Mandatory=$True)]
        [string]$ZuulProject,
        [string]$GitOrigin,
        [string]$ZuulNewrev
    )

    if (!$ZuulRef -or !$ZuulChange -or !$ZuulProject) {
        Throw "ZUUL_REF ZUUL_CHANGE ZUUL_PROJECT are mandatory"
    }
    if (!$ZuulUrl) {
        Throw "The zuul site name (eg 'http://zuul.openstack.org/p') must be the first argument."
    }
    if (!$GerritSite) {
        Throw "The gerrit site name (eg 'https://review.openstack.org') must be the second argument."
    }
    if (!$GitOrigin -or !$ZuulNewrev) {
        $GitOrigin="$GerritSite/p"
    }

    Write-JujuLog "Triggered by: $GerritSite/$ZuulChange"

    if (!(Test-Path -Path $BUILD_DIR -PathType Container)) {
        mkdir $BUILD_DIR
    }

    $projectDir = Join-Path $BUILD_DIR $ZuulProject
    if (!(Test-Path -Path $projectDir -PathType Container)) {
        mkdir $projectDir
        try {
            Execute-ExternalCommand { git clone "$GitOrigin/$ZuulProject" $projectDir } `
                -ErrorMessage "Failed to clone $GitOrigin/$ZuulProject"
        } catch {
            rm -Recurse -Force $projectDir
            Throw $_
        }
    }

    pushd $projectDir

    Execute-ExternalCommand { git remote set-url origin "$GitOrigin/$ZuulProject" } `
        -ErrorMessage "Failed to set origin: $GitOrigin/$ZuulProject"

    try {
        Execute-ExternalCommand { git remote update } -ErrorMessage "Failed to update remote"
    } catch {
        Write-JujuLog "The remote update failed, so garbage collecting before trying again."
        Execute-ExternalCommand { git gc } -ErrorMessage "Failed to run git gc."
        Execute-ExternalCommand { git remote update } -ErrorMessage "Failed to update remote"
    }

    Execute-ExternalCommand { git reset --hard } -ErrorMessage "Failed to git reset"
    try {
        Execute-ExternalCommand { git clean -x -f -d -q } -ErrorMessage "Failed to git clean"
    } catch {
        sleep 1
        Execute-ExternalCommand { git clean -x -f -d -q } -ErrorMessage "Failed to git clean"
    }

    echo "Before doing git checkout:"
    echo "Git branch output:"
    Execute-ExternalCommand { git branch } -ErrorMessage "Failed to show git branch."
    echo "Git log output:"
    Execute-ExternalCommand { git log -10 --pretty=format:"%h - %an, %ae, %ar : %s" } `
        -ErrorMessage "Failed to show git log."

    $ret = echo "$ZuulRef" | Where-Object { $_ -match "^refs/tags/" }
    if ($ret) {
        Execute-ExternalCommand { git fetch --tags "$ZuulUrl/$ZuulProject" } `
            -ErrorMessage "Failed to fetch tags from: $ZuulUrl/$ZuulProject"
        Execute-ExternalCommand { git checkout $ZuulRef } `
            -ErrorMessage "Failed to fetch tags to: $ZuulRef"
        Execute-ExternalCommand { git reset --hard $ZuulRef } `
            -ErrorMessage "Failed to hard reset to: $ZuulRef"
    } elseif (!$ZuulNewrev) {
        Execute-ExternalCommand { git fetch "$ZuulUrl/$ZuulProject" $ZuulRef } `
            -ErrorMessage "Failed to fetch: $ZuulUrl/$ZuulProject $ZuulRef"
        Execute-ExternalCommand { git checkout FETCH_HEAD } `
            -ErrorMessage "Failed to checkout FETCH_HEAD"
        Execute-ExternalCommand { git reset --hard FETCH_HEAD } `
            -ErrorMessage "Failed to hard reset FETCH_HEAD"
    } else {
        Execute-ExternalCommand { git checkout $ZuulNewrev } `
            -ErrorMessage "Failed to checkout $ZuulNewrev"
        Execute-ExternalCommand { git reset --hard $ZuulNewrev } `
            -ErrorMessage "Failed to hard reset $ZuulNewrev"
    }

    try {
        Execute-ExternalCommand { git clean -x -f -d -q } -ErrorMessage "Failed to git clean"
    } catch {
        sleep 1
        Execute-ExternalCommand { git clean -x -f -d -q } -ErrorMessage "Failed to git clean"
    }

    if (Test-Path .gitmodules) {
        Execute-ExternalCommand { git submodule init } -ErrorMessage "Failed to init submodule"
        Execute-ExternalCommand { git submodule sync } -ErrorMessage "Failed to sync submodule"
        Execute-ExternalCommand { git submodule update --init } -ErrorMessage "Failed to update submodule"
    }

    echo "Final result:"
    echo "Git branch output:"
    Execute-ExternalCommand { git branch } -ErrorMessage "Failed to show git branch."
    echo "Git log output:"
    Execute-ExternalCommand { git log -10 --pretty=format:"%h - %an, %ae, %ar : %s" } `
        -ErrorMessage "Failed to show git log."

    popd
}


function Render-ConfigFile {
    Param(
        [string]$TemplatePath,
        [string]$ConfPath,
        [HashTable]$Configs
    )

    $template = Get-Content $TemplatePath
    foreach ($config in $Configs.GetEnumerator()) {
        $regex = "{{\s*" + $config.Name + "\s*}}"
        $template = $template | ForEach-Object { $_ -replace $regex,$config.Value }
    }

    Set-Content $ConfPath $template
}


function Create-Environment {
    Param(
        [string]$BranchName='master',
        [string]$BuildFor='openstack/nova'
    )

    $dirs = @($CONFIG_DIR, $BIN_DIR, $INSTANCES_DIR, $LOG_DIR, $SERVICE_DIR)
    foreach($dir in $dirs) {
        if (!(Test-Path $dir)) {
            Write-JujuLog "Creating $dir folder."
            mkdir $dir
        }
    }

    $mkisofsPath = Join-Path $BIN_DIR "mkisofs.exe"
    $qemuimgPath = Join-Path $BIN_DIR "qemu-img.exe"
    if (!(Test-Path $mkisofsPath) -or !(Test-Path $qemuimgPath)) {
        Write-JujuLog "Downloading OpenStack binaries..."
        $zipPath = Join-Path $FILES_DIR "openstack_bin.zip"
        Unzip-With7z $zipPath $BIN_DIR
    }

    Write-JujuLog "Cloning the required Git repositories..."
    $openstackBuild = Join-Path $BUILD_DIR "openstack"
    if ($BuildFor -eq "openstack/nova") {
        Write-JujuLog "Cloning neutron from $NEUTRON_GIT $BranchName..."
        ExecuteWith-Retry {
            Run-GitClonePull "$openstackBuild\neutron" $NEUTRON_GIT $BranchName
        }
        Write-JujuLog "Cloning $NETWORKING_HYPERV_GIT from master..."
        ExecuteWith-Retry {
            Run-GitClonePull "$openstackBuild\networking-hyperv" $NETWORKING_HYPERV_GIT "master"
        }
    } elseif (($BuildFor -eq "openstack/neutron") -or ($BuildFor -eq "openstack/quantum")) {
        Write-JujuLog "Cloning $NOVA_GIT from $BranchName..."
        ExecuteWith-Retry {
            Run-GitClonePull "$openstackBuild\nova" $NOVA_GIT $BranchName
        }
        Write-JujuLog "Cloning $NETWORKING_HYPERV_GIT from master..."
        ExecuteWith-Retry {
            Run-GitClonePull "$openstackBuild\networking-hyperv" $NETWORKING_HYPERV_GIT "master"
        }
    } elseif ($buildFor -eq "stackforge/networking-hyperv") {
        Write-JujuLog "Cloning $NOVA_GIT from $BranchName..."
        ExecuteWith-Retry {
            Run-GitClonePull "$openstackBuild\nova" $NOVA_GIT $BranchName
        }
        Write-JujuLog "Cloning neutron from $NEUTRON_GIT $BranchName..."
        ExecuteWith-Retry {
            Run-GitClonePull "$openstackBuild\neutron" $NEUTRON_GIT $BranchName
        }
    } else {
        Throw "Cannot build for project: $BuildFor"
    }

    Write-JujuLog "Installing neutron..."
    ExecuteWith-Retry {
        Install-OpenStackProjectFromRepo "$openstackBuild\neutron"
    }
    if (!(Test-Path $NEUTRON_SERVICE_EXECUTABLE)) {
        Throw "$NEUTRON_SERVICE_EXECUTABLE was not found."
    }

    Write-JujuLog "Installing networking-hyperv..."
    ExecuteWith-Retry {
        Install-OpenStackProjectFromRepo "$openstackBuild\networking-hyperv"
    }

    Write-JujuLog "Installing nova..."
    ExecuteWith-Retry {
        Install-OpenStackProjectFromRepo "$openstackBuild\nova"
    }
    if (!(Test-Path $NOVA_SERVICE_EXECUTABLE)) {
        Throw "$NOVA_SERVICE_EXECUTABLE was not found."
    }

    Write-JujuLog "Copying default config files..."
    $defaultConfigFiles = @('rootwrap.d', 'api-paste.ini', 'cells.json',
                            'policy.json','rootwrap.conf')
    foreach ($config in $defaultConfigFiles) {
        Copy-Item -Recurse -Force "$openstackBuild\nova\etc\nova\$config" $CONFIG_DIR
    }
    Copy-Item -Force (Join-Path (Get-TemplatesDir) "interfaces.template") $CONFIG_DIR

    Write-JujuLog "Environment initialization done."
}


function Generate-ConfigFiles {
    Param(
        [string]$DevStackIP,
        [string]$DevStackPassword,
        [string]$RabbitUser
    )

    Write-JujuLog "Generating Nova config file"
    $novaTemplate = Join-Path (Get-TemplatesDir) "nova.conf"
    $configs = @{
        "instances_path"      = Join-Path $OPENSTACK_DIR "Instances";
        "interfaces_template" = Join-Path $CONFIG_DIR "interfaces.template";
        "policy_file"         = Join-Path $CONFIG_DIR "policy.json";
        "mkisofs_exe"         = Join-Path $BIN_DIR "mkisofs.exe";
        "devstack_ip"         = $DevStackIP;
        "rabbit_user"         = $RabbitUser;
        "rabbit_password"     = $DevStackPassword;
        "log_directory"       = $LOG_DIR;
        "qemu_img_exe"        = Join-Path $BIN_DIR "qemu-img.exe";
        "admin_password"      = $DevStackPassword;
        "vswitch_name"        = Get-JujuVMSwitchName
    }
    Render-ConfigFile -TemplatePath $novaTemplate `
                      -ConfPath $NOVA_SERVICE_CONFIG `
                      -Configs $configs

    Write-JujuLog "Generating Neutron config file"
    $neutronTemplate = Join-Path (Get-TemplatesDir) "neutron_hyperv_agent.conf"
    $configs = @{
        "policy_file"     = Join-Path $CONFIG_DIR "policy.json";
        "devstack_ip"     = $DevStackIP;
        "rabbit_user"     = $RabbitUser;
        "rabbit_password" = $DevStackPassword;
        "log_directory"   = $LOG_DIR;
        "admin_password"  = $DevStackPassword;
        "vswitch_name"    = Get-JujuVMSwitchName
    }
    Render-ConfigFile -TemplatePath $neutronTemplate `
                      -ConfPath $NEUTRON_SERVICE_CONFIG `
                      -Configs $configs
}


function Set-ServiceAcountCredentials {
    Param(
        [string]$ServiceName,
        [string]$ServiceUser,
        [string]$ServicePassword
    )

    $filter = 'Name=' + "'" + $ServiceName + "'" + ''
    $service = Get-WMIObject -Namespace "root\cimv2" -Class Win32_Service -Filter $filter
    $service.StopService()
    while ($service.Started) {
        Start-Sleep -Seconds 2
        $service = Get-WMIObject -Namespace "root\cimv2" -Class Win32_Service -Filter $filter
    }

    Set-UserLogonAsServiceRights $ServiceUser

    $service.Change($null, $null, $null, $null, $null, $null, $ServiceUser, $ServicePassword)
}


function Create-OpenStackService {
    Param(
        [string]$ServiceName,
        [string]$ServiceDescription,
        [string]$ServiceExecutable,
        [string]$ServiceConfig,
        [string]$ServiceUser,
        [string]$ServicePassword
    )

    $filter='Name=' + "'" + $ServiceName + "'"

    $service = Get-WmiObject -Namespace "root\cimv2" -Class Win32_Service -Filter $filter
    if($service) {
        Write-JujuLog "Service $ServiceName is already created."
        return $true
    }

    $serviceFileName = "OpenStackService.exe"
    if(!(Test-Path "$SERVICE_DIR\$serviceFileName")) {
        Copy-Item "$FILES_DIR\$serviceFileName" "$SERVICE_DIR\$serviceFileName"
    }

    New-Service -Name "$ServiceName" `
                -BinaryPathName "$SERVICE_DIR\$serviceFileName $ServiceName $ServiceExecutable --config-file $ServiceConfig" `
                -DisplayName "$ServiceName" `
                -Description "$ServiceDescription" `
                -StartupType "Manual"

    if((Get-Service -Name $ServiceName).Status -eq "Running") {
        Stop-Service $ServiceName
    }

    Set-ServiceAcountCredentials $ServiceName $ServiceUser $ServicePassword
}


function Poll-ServiceStatus {
    Param(
        [string]$ServiceName,
        [int]$IntervalSeconds
    )

    $count = 0
    while ($count -lt $IntervalSeconds) {
        if ((Get-Service -Name $ServiceName).Status -ne "Running") {
            Throw "$ServiceName has errors. Please check the logs."
        }
        $count += 1
        Start-Sleep -Seconds 1
    }
}


function Get-JujuVMSwitchName {
    $VMswitchName = Get-JujuCharmConfig -scope "vmswitch-name"
    if (!$VMswitchName){
        return "br100"
    }
    return $VMswitchName
}


function Get-InterfaceFromConfig {
    Param (
        [string]$ConfigOption="data-port",
        [switch]$MustFindAdapter=$false
    )

    $nic = $null
    $DataInterfaceFromConfig = Get-JujuCharmConfig -scope $ConfigOption
    Write-JujuLog "Looking for $DataInterfaceFromConfig"
    if ($DataInterfaceFromConfig -eq $false -or $DataInterfaceFromConfig -eq "") {
        return $null
    }
    $byMac = @()
    $byName = @()
    $macregex = "^([a-f-A-F0-9]{2}:){5}([a-fA-F0-9]{2})$"
    foreach ($i in $DataInterfaceFromConfig.Split()) {
        if ($i -match $macregex) {
            $byMac += $i.Replace(":", "-")
        } else {
            $byName += $i
        }
    }
    Write-JujuLog "We have MAC: $byMac  Name: $byName"
    if ($byMac.Length -ne 0){
        $nicByMac = Get-NetAdapter | Where-Object { $_.MacAddress -in $byMac }
    }
    if ($byName.Length -ne 0){
        $nicByName = Get-NetAdapter | Where-Object { $_.Name -in $byName }
    }
    if ($nicByMac -ne $null -and $nicByMac.GetType() -ne [System.Array]){
        $nicByMac = @($nicByMac)
    }
    if ($nicByName -ne $null -and $nicByName.GetType() -ne [System.Array]){
        $nicByName = @($nicByName)
    }
    $ret = $nicByMac + $nicByName
    if ($ret.Length -eq 0 -and $MustFindAdapter){
        Throw "Could not find network adapters"
    }
    return $ret
}


function Configure-VMSwitch {
    $managementOS = Get-JujuCharmConfig -scope 'vmswitch-management'
    $VMswitchName = Get-JujuVMSwitchName

    try {
        $isConfigured = Get-VMSwitch -SwitchType External -Name $VMswitchName -ErrorAction SilentlyContinue
    } catch {
        $isConfigured = $false
    }

    if ($isConfigured) {
        return $true
    }
    $VMswitches = Get-VMSwitch -SwitchType External
    if ($VMswitches.Count -gt 0){
        Rename-VMSwitch $VMswitches[0] -NewName $VMswitchName
        return $true
    }

    $interfaces = Get-NetAdapter -Physical | Where-Object { $_.Status -eq "Up" }

    if ($interfaces.GetType().BaseType -ne [System.Array]){
        # we have ony one ethernet adapter. Going to use it for
        # vmswitch
        New-VMSwitch -Name $VMswitchName -NetAdapterName $interfaces.Name -AllowManagementOS $true
        if ($? -eq $false) {
            Throw "Failed to create vmswitch"
        }
    } else {
        Write-JujuLog "Trying to fetch data port from config"
        $nic = Get-InterfaceFromConfig -MustFindAdapter
        Write-JujuLog "Got NetAdapterName $nic"
        New-VMSwitch -Name $VMswitchName -NetAdapterName $nic[0].Name -AllowManagementOS $managementOS
        if ($? -eq $false){
            Throw "Failed to create vmswitch"
        }
    }
    $hasVM = Get-VM
    if ($hasVM){
        Connect-VMNetworkAdapter * -SwitchName $VMswitchName
        Start-VM *
    }
    return $true
}


function Get-HostFromURL {
    Param(
        [string]$URL
    )

    $uri = [System.Uri]$URL
    return $uri.Host
}


function Install-Dependency {
    Param(
        [string]$URLConfigKey,
        [array]$ArgumentList
    )

    $urlChecksum = Get-URLChecksum $URLConfigKey
    if ($urlChecksum['CHECKSUM'] -and $urlChecksum['HASHING_ALGORITHM']) {
        Install-Package -URL $urlChecksum['URL'] `
                        -Checksum $urlChecksum['CHECKSUM'] `
                        -HashingAlgorithm $urlChecksum['HASHING_ALGORITHM'] `
                        -ArgumentList $ArgumentList
    } else {
        Install-Package -URL $urlChecksum['URL'] -ArgumentList $ArgumentList
    }
}


function Install-FreeRDPConsole {
    Write-JujuLog "Installing FreeRDP..."

    Install-Dependency 'vc-2012-url' @('/q')

    $freeRDPZip = Join-Path $FILES_DIR "FreeRDP_powershell.zip"
    $charmLibDir = Join-Path (Get-JujuCharmDir) "lib"
    Unzip-With7z $freeRDPZip $charmLibDir

    # Copy wfreerdp.exe and DLL file to Windows folder
    $freeRDPFiles = @('wfreerdp.exe', 'libeay32.dll', 'ssleay32.dll')
    $windows = Join-Path $env:SystemDrive "Windows"
    foreach ($file in $freeRDPFiles) {
        Copy-Item "$charmLibDir\FreeRDP\$file" $windows
    }

    $freeRDPModuleFolder = Join-Path $windows "system32\WindowsPowerShell\v1.0\Modules\FreeRDP"
    if (!(Test-Path $freeRDPModuleFolder)) {
        mkdir $freeRDPModuleFolder
    }
    Copy-Item "$charmLibDir\FreeRDP\FreeRDP.psm1" $freeRDPModuleFolder
    Remove-Item -Recurse "$charmLibDir\FreeRDP"

    Write-JujuLog "Finished installing FreeRDP."
}


function Generate-PipConfigFile {
    $pypiMirror = Get-JujuCharmConfig -scope 'pypi-mirror'
    if (!$pypiMirror) {
        $pypiMirror = Get-JujuCharmConfig -scope 'ppy-mirror'
    }
    if ($pypiMirror -eq $null -or $pypiMirror.Length -eq 0) {
        Write-JujuLog ("pypi-mirror config is not present. " +
                       "Will not generate the pip.ini file.")
        return
    }
    $pipDir = Join-Path $env:APPDATA "pip"
    if (!(Test-Path $pipDir)){
        mkdir $pipDir
    } else {
        Remove-Item -Force "$pipDir\*"
    }
    $pipIni = Join-Path $pipDir "pip.ini"
    New-Item -ItemType File $pipIni

    $mirrors = $pypiMirror.Split()
    $hosts = @()
    foreach ($i in $mirrors){
        $h = Get-HostFromURL $i
        if ($h -in $hosts) {
            continue
        }
        $hosts += $h
    }

    Set-IniFileValue "index-url" "global" $mirrors[0] $pipIni
    if ($mirrors.Length -gt 1){
        Set-IniFileValue "extra-index-url" "global" ($mirrors[1..$mirrors.Length] -Join " ") $pipIni
    }
    Set-IniFileValue "trusted-host" "install" ($hosts -Join " ") $pipIni
}


function Get-HypervADUser {
    $adUsername = Get-JujuCharmConfig -scope 'ad-user-name'
    if (!$adUsername) {
        $adUsername = "hyper-v-user"
    }
    return $adUsername
}


function Set-ADRelationParams {
    $hypervADUser = Get-HypervADUser
    $userGroup = @{
        $hypervADUser = @( )
    }
    $encUserGroup = Marshall-Object $userGroup
    $relationParams = @{
        'adusers' = $encUserGroup;
    }
    $ret = Set-JujuRelation -Relation_Settings $relationParams
    if ($ret -eq $false) {
       Write-JujuError "Failed to set AD relation parameters."
    }
}


function Set-CharmStatus {
    Param(
        [string]$Status
    )

    Execute-ExternalCommand {
        status-set.exe $Status
    } -ErrorMessage "Failed to set charm status to '$Status'."
}


function Set-DevStackRelationParams {
    Param(
        [HashTable]$RelationParams
    )

    $rids = Get-JujuRelationIds -RelType "devstack"
    foreach ($rid in $rids) {
        $ret = Set-JujuRelation -Relation_Id $rid -Relation_Settings $RelationParams
        if ($ret -eq $false) {
           Write-JujuError "Failed to set DevStack relation parameters."
        }
    }
}


# HOOKS FUNCTIONS

function Run-InstallHook {
    # Disable firewall
    Execute-ExternalCommand {
        netsh.exe advfirewall set allprofiles state off
    } -ErrorMessage "Failed to disable firewall."

    Configure-VMSwitch
    Generate-PipConfigFile

    # Install Git
    Install-Dependency 'git-url' @('/SILENT')
    AddTo-UserPath "${env:ProgramFiles(x86)}\Git\cmd"
    Renew-PSSessionPath

    # Install 7z
    Install-Dependency '7z-url' @('/S')
    AddTo-UserPath "${env:ProgramFiles(x86)}\7-Zip"
    Renew-PSSessionPath

    # Install Python 2.7.x (x86)
    Install-Dependency 'python27-url' @('/qn')
    AddTo-UserPath "${env:SystemDrive}\Python27;${env:SystemDrive}\Python27\scripts"
    Renew-PSSessionPath

    # Install FreeRDP Hyper-V console access
    $enableFreeRDP = Get-JujuCharmConfig -scope 'enable-freerdp-console'
    if ($enableFreeRDP -eq $true) {
        Install-FreeRDPConsole
    }

    # Install extra python packages
    Write-JujuLog "Installing pip dependencies..."
    $getPip = Download-File -DownloadLink "https://bootstrap.pypa.io/get-pip.py"
    Execute-ExternalCommand -Command { python $getPip } `
                            -ErrorMessage "Failed to install pip."

    $version = & pip --version
    Write-JujuLog "Pip version: $version"

    $pythonPkgs = Get-JujuCharmConfig -scope 'extra-python-packages'
    if ($pythonPkgs) {
        $pythonPkgsArr = $pythonPkgs.Split()
        foreach ($pythonPkg in $pythonPkgsArr) {
            Write-JujuLog "Installing $pythonPkg..."
            Execute-ExternalCommand -Command { pip install -U $pythonPkg } `
                                    -ErrorMessage "Failed to install $pythonPkg"
        }
    }

    # Install posix_ipc
    Write-JujuLog "Installing posix_ipc library..."
    $zipPath = Join-Path $FILES_DIR "posix_ipc.zip"
    Unzip-With7z $zipPath $LIB_DIR

    Write-JujuLog "Installing pywin32..."
    Execute-ExternalCommand -Command { pip install pywin32 } `
                            -ErrorMessage "Failed to install pywin32."
    Execute-ExternalCommand {
        python "$PYTHON_DIR\Scripts\pywin32_postinstall.py" -install
    } -ErrorMessage "Failed to run pywin32_postinstall.py"

    Write-JujuLog "Running Git Prep..."
    $zuulUrl = Get-JujuCharmConfig -scope 'zuul-url'
    $zuulRef = Get-JujuCharmConfig -scope 'zuul-ref'
    $zuulChange = Get-JujuCharmConfig -scope 'zuul-change'
    $zuulProject = Get-JujuCharmConfig -scope 'zuul-project'
    $gerritSite = $zuulUrl.Trim('/p')
    Run-GerritGitPrep -ZuulUrl $zuulUrl `
                      -GerritSite $gerritSite `
                      -ZuulRef $zuulRef `
                      -ZuulChange $zuulChange `
                      -ZuulProject $zuulProject

    $gitEmail = Get-JujuCharmConfig -scope 'git-user-email'
    $gitName = Get-JujuCharmConfig -scope 'git-user-name'
    Execute-ExternalCommand { git config --global user.email $gitEmail } `
        -ErrorMessage "Failed to set git global user.email"
    Execute-ExternalCommand { git config --global user.name $gitName } `
        -ErrorMessage "Failed to set git global user.name"
    $zuulBranch = Get-JujuCharmConfig -scope 'zuul-branch'

    Write-JujuLog "Creating the Environment..."
    Create-Environment -BranchName $zuulBranch `
                       -BuildFor $zuulProject
}


function Run-ADRelationJoinedHook {
    Set-ADRelationParams
}


function Run-RelationHooks {
    Renew-PSSessionPath
    $adCtx = Get-ADContext

    if (!$adCtx["context"]) {
        Write-JujuLog "AD context is not ready."
    } else {
        if (!(Is-InDomain $adCtx["ad_domain"])) {
            ConnectTo-ADController $adCtx
            ExitFrom-JujuHook -WithReboot
        } else {
            Write-JujuLog "AD domain already joined."
        }

        $adUserCreds = Unmarshall-Object $adCtx["ad_credentials"]
        $adUser = $adUserCreds.PSObject.Properties.Name
        $adUserPassword = $adUserCreds.PSObject.Properties.Value
        $domainUser = $adCtx["ad_domain"] + "\" + $adUser

        $adUserCred = @{
            'domain'   = $adCtx["ad_domain"];
            'username' = $adUser;
            'password' = $adUserPassword
        }
        $encADUserCred = Marshall-Object $adUserCred
        $relationParams = @{ 'ad_credentials' = $encADUserCred; }
        Set-DevStackRelationParams $relationParams

        # Add AD user to local Administrators group
        Add-UserToLocalAdminsGroup $adCtx["ad_domain"] $adUser

        Create-OpenStackService $NOVA_SERVICE_NAME $NOVA_SERVICE_DESCRIPTION `
                      $NOVA_SERVICE_EXECUTABLE $NOVA_SERVICE_CONFIG `
                      $domainUser $adUserPassword
        Create-OpenStackService $NEUTRON_SERVICE_NAME $NEUTRON_SERVICE_DESCRIPTION `
                      $NEUTRON_SERVICE_EXECUTABLE $NEUTRON_SERVICE_CONFIG `
                      $domainUser $adUserPassword
    }

    $devstackCtx = Get-DevStackContext
    if (!$devstackCtx['context']) {
        Write-JujuLog ("DevStack context is not ready. Will not generate config files.")
    } else {
        Generate-ConfigFiles -DevStackIP $devstackCtx['devstack_ip'] `
                             -DevStackPassword $devstackCtx['devstack_password'] `
                             -RabbitUser $devstackCtx['rabbit_user']
    }

    if (!$devstackCtx['context'] -or !$adCtx['context']) {
        Write-JujuLog ("AD context and DevStack context must be complete " +
                       "before starting the OpenStack services.")
    } else {
        Write-JujuLog "Starting OpenStack services..."

        Write-JujuLog "Starting $NOVA_SERVICE_NAME service"
        Start-Service -ServiceName $NOVA_SERVICE_NAME
        Write-JujuLog "Polling $NOVA_SERVICE_NAME service status for 60 seconds."
        Poll-ServiceStatus $NOVA_SERVICE_NAME -IntervalSeconds 60

        Write-JujuLog "Starting $NEUTRON_SERVICE_NAME service"
        Start-Service -ServiceName $NEUTRON_SERVICE_NAME
        Write-JujuLog "Polling $NEUTRON_SERVICE_NAME service status for 60 seconds."
        Poll-ServiceStatus $NEUTRON_SERVICE_NAME -IntervalSeconds 60

        Start-Service "MSiSCSI"

        Set-CharmStatus "active"
    }
}


Export-ModuleMember -Function Run-InstallHook
Export-ModuleMember -Function Run-ADRelationJoinedHook
Export-ModuleMember -Function Run-RelationHooks
