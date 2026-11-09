param(
    [Parameter(Position = 0)]
    [ValidateSet('Start', 'Stop', 'Connect', 'Disconnect')]
    [string]$Action = 'Start'
)

# 定时设置：每 30 分钟连接一次，修改后再次双击启动即可生效。
$IntervalMinutes = 30
$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'suda-campus.json'
$logPath = Join-Path $PSScriptRoot '运行日志.txt'
$gatewayHost = '10.9.1.3'
$taskName = 'SudaCampusGatewayReconnect-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Write-Status([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Write-Host $line
    try {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 65536) {
            Set-Content -LiteralPath $logPath -Value '' -Encoding UTF8
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { Write-Warning '无法写入运行日志。' }
}

function Read-Config([switch]$AllowSetup) {
    if (-not (Test-Path -LiteralPath $configPath)) { throw '找不到 suda-campus.json，请把配置文件和脚本放在同一文件夹。' }
    try { $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json }
    catch { throw '配置文件不是有效 JSON，请检查引号和逗号，或参照使用说明修改。' }
    if (($config.Username -isnot [string]) -or ($config.Password -isnot [string])) {
        throw '配置文件中 Username 和 Password 必须是字符串。'
    }
    if ([string]::IsNullOrWhiteSpace($config.Username) -or [string]::IsNullOrEmpty($config.Password)) {
        if (-not $AllowSetup) { throw '请先双击启动文件，填写校园网账号和密码。' }
        Write-Host '请选择校园网运营商：'
        Write-Host '  1. 学校校园网'
        Write-Host '  2. 中国移动'
        Write-Host '  3. 中国联通'
        Write-Host '  4. 中国电信'
        $providers = @{
            '1' = @{ Name = '学校校园网'; Suffix = '' }
            '2' = @{ Name = '中国移动'; Suffix = '@zgyd' }
            '3' = @{ Name = '中国联通'; Suffix = '@cucc' }
            '4' = @{ Name = '中国电信'; Suffix = '@ctc' }
        }
        do { $providerChoice = Read-Host '请输入选项编号（1-4）' }
        until ($providers.ContainsKey($providerChoice))
        $provider = $providers[$providerChoice]
        $username = Read-Host "请输入$($provider.Name)账号（不含运营商后缀）"
        if ($provider.Suffix -and -not $username.EndsWith($provider.Suffix, [StringComparison]::OrdinalIgnoreCase)) {
            $username += $provider.Suffix
        }
        $secret = Read-Host '请输入校园网密码（输入时不显示）' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
        try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrEmpty($password)) { throw '账号和密码不能为空。' }
        $config = [pscustomobject]@{ Provider = $provider.Name; Username = $username; Password = $password; AdapterName = [string]$config.AdapterName }
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    if ($config.AdapterName -and ($config.AdapterName -isnot [string])) { throw 'AdapterName 必须是网卡名称字符串。' }
    return $config
}

function Get-CampusIp($Config) {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface })
    if ($Config.AdapterName) { $adapters = @($adapters | Where-Object { $_.Name -eq $Config.AdapterName }) }
    $addresses = @(
        foreach ($adapter in $adapters) {
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' -and $_.AddressState -eq 'Preferred' } |
                Select-Object -ExpandProperty IPAddress
        }
    )
    if ($addresses.Count -eq 0) { throw '没有可用的有线或无线 IPv4 地址。请连接校园网网线或 Wi-Fi，必要时填写配置中的 AdapterName。' }
    if ($addresses.Count -eq 1) { return $addresses[0] }
    # 多网卡时优先使用 Windows 到校园网网关的路由所选源地址。
    $routeAddresses = @(Find-NetRoute -RemoteIPAddress $gatewayHost -ErrorAction Stop |
        Where-Object { $_.IPAddress -and ($addresses -contains $_.IPAddress) } |
        Select-Object -ExpandProperty IPAddress -Unique)
    if ($routeAddresses.Count -eq 1) { return $routeAddresses[0] }
    throw '有多个可用地址，无法自动确定校园网接口。请在 suda-campus.json 的 AdapterName 中填写校园网网卡名称（可通过 Get-NetAdapter 查看）。'
}

function Invoke-GatewayRequest([string]$Uri) {
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 10 -UseBasicParsing -MaximumRedirection 0
    } catch { throw '无法访问校园网网关（请求失败或超时）。请检查校园网连接及 VPN/代理。' }
    $body = ([string]$response.Content).Trim()
    if ($body -match '(?s)^(?:[A-Za-z_$][\w$]*\s*)?\((.*)\)\s*;?$') { $body = $Matches[1] }
    try { $result = $body | ConvertFrom-Json }
    catch { throw '网关响应不是预期的 JSON/JSONP，可能需要更新网关协议。' }
    if ($null -eq $result -or $null -eq $result.result) { throw '网关响应缺少 result 字段。' }
    return $result
}

function Connect-Campus($Config) {
    $ip = Get-CampusIp $Config
    $account = [uri]::EscapeDataString(',0,' + $Config.Username)
    $password = [uri]::EscapeDataString($Config.Password)
    $uri = "http://${gatewayHost}:801/eportal/?c=Portal&a=login&login_method=1&user_account=$account&user_password=$password&wlan_user_ip=$ip"
    $result = Invoke-GatewayRequest $uri
    if ([string]$result.result -eq '1') { Write-Status "连接成功（$ip）。" }
    elseif ([string]$result.result -eq '0' -and [string]$result.ret_code -eq '2') { Write-Status "已经连接（$ip）。" }
    else { throw '校园网登录失败，请检查账号、密码、运营商后缀或学校门户提示。' }
}

function Disconnect-Campus($Config) {
    $ip = Get-CampusIp $Config
    $uri = "http://${gatewayHost}:801/eportal/?c=Portal&a=logout&login_method=1&wlan_user_ip=$ip"
    $result = Invoke-GatewayRequest $uri
    if ([string]$result.result -eq '1') { Write-Status "网关返回断开成功（$ip）。" }
    else { throw '网关未确认断开成功。定时连接已停止时不会再自动重连；请到学校门户确认登出。' }
}

function Install-Schedule {
    if ($IntervalMinutes -lt 5 -or $IntervalMinutes -gt 1440) { throw '定时间隔必须为 5 到 1440 分钟。' }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Connect' -f $PSCommandPath
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $PSScriptRoot
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $login = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger @($repeat, $login) -Principal $principal -Settings $settings -Description ("校园网自动连接：用户登录及每 $IntervalMinutes 分钟触发，执行后退出。") -Force | Out-Null
}

function Get-ExistingSchedule([string]$Name) {
    try { return Get-ScheduledTask -TaskName $Name -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return $null }
        throw '无法读取 Windows 任务计划。请检查系统任务计划服务或权限，自动连接状态尚未确认。'
    }
}

function Remove-Schedule {
    $existing = Get-ExistingSchedule $taskName
    if ($existing) {
        Disable-ScheduledTask -InputObject $existing -ErrorAction Stop | Out-Null
        if ($existing.State -eq 'Running') { Stop-ScheduledTask -InputObject $existing -ErrorAction Stop }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    }
    # 兼容移除旧版本使用的固定名称任务。
    $legacy = Get-ExistingSchedule 'SudaCampusGatewayReconnect'
    if ($legacy) {
        Disable-ScheduledTask -InputObject $legacy -ErrorAction Stop | Out-Null
        if ($legacy.State -eq 'Running') { Stop-ScheduledTask -InputObject $legacy -ErrorAction Stop }
        Unregister-ScheduledTask -TaskName $legacy.TaskName -Confirm:$false -ErrorAction Stop
    }
}

try {
    switch ($Action) {
        Start {
            $config = Read-Config -AllowSetup
            Remove-Schedule
            Install-Schedule
            Write-Status "自动连接已开启：每 $IntervalMinutes 分钟运行一次，下次登录 Windows 时也会连接。可关闭此窗口。"
            Connect-Campus $config
        }
        Stop {
            Remove-Schedule
            Write-Status '自动连接已停止，正在尝试网关登出。'
            $config = Read-Config
            Disconnect-Campus $config
        }
        Connect { $config = Read-Config; Connect-Campus $config }
        Disconnect { $config = Read-Config; Disconnect-Campus $config }
    }
    exit 0
} catch {
    Write-Status ('失败：' + $_.Exception.Message)
    exit 1
}
