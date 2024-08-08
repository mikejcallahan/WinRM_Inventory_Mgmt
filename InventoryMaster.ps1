
[string]$currentPSuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
[string]$currentPSUserNotFQ = [string](($currentPSuser -split '\\')[-1])
[string]$version = "1.2.1"

  write-host ("
  ***********************************************************************************************************
  Inventory Management Master $($version) | Pleroma Tech LLC | Mike J Callahan 2023 | MIT license 

  Requires WinRM service and firewall exception on target machines. Invokes commands on PCs listed in PCList.txt file. Estimates primary user 
  with temp folder if no Explorer.exe owner exists - otherwise this is given priority. Estimated user, PC name and serialnumber are included in 
  filename of CSV reports. PSuser($currentPSuser), username in passed credentials, system and default user profiles, and users in ignore txt file are 
  skipped/ignored so report name won't include these. Additional usernames can be added to ignoreList. If no user can be estimated 'UNKNOWN' is used. 
  *list files will be created(If missing) after initializing and will give instructions for using. PC list requires at least 1 target PC.

  COMMANDS: get-package -Provider Programs -includewindowsinstaller

  ***********************************************************************************************************
  USAGE: type 'initialize_inventory -start' <ENTER>

  INTERACTIVE:           -start
  CONSOLE:               -utility
  CONSOLE LOOP:          -utility -loop
  EDIT PCLIST:           -pclistedit
  ADDITIONAL INFO ADD:   -dev
  ************************************************************************************************************
  ")

function Initialize_Inventory([switch]$start,[switch]$utility,[switch]$loop,[switch]$dev,[switch]$pclistedit) {
  [string]$domain =               "pleromatech.net"
  [string]$logServer =            "$($env:COMPUTERNAME)"                  <# NEED TO DETERMINE WHETHER I HANDLED MAKING STORE AND LOGSERVER NOT INTERDEPENDENT #>
  [string]$logServerStore =       "$($PSscriptRoot)"                      <# LOCAL FULL PATH HERE, GETS CONVERTED TO REMOTE PATH LATER. #>
  [string]$logServerPCDir =       "$($logServerStore)\PC"
  [string]$primaryUserEstimator = ".\primaryUserEstimator_IgnoreList.txt"
  [string]$defaultPCList =        ".\PCList.txt"
  [string]$pingEnginePath =       ".\util\pcping5.exe"                    <# THIS IS SEPARATE CONSOLE APP THAT TAKES STRING[] OF PC NAMES AND RETURNS NOT-ONLINE LIST. REG PING USED IF MISSING #>
  
  [string]$stage =                "$($env:userprofile)\appdata\local\$($domain)_INV"
  

  function inventory1 ([string[]]$pclist, [string]$injectInfo, [switch]$cacheReset) {
      write-host ("
      $injectInfo
      ***********************************************************************************************************") 
      try{
        if ($null -eq $creds) {                                                                        <# preventing constant cred punching #>
	      $global:creds = Get-Credential -message "CREDS TO USE ON TARGETS" -ErrorAction stop
          if($null -eq $creds) { write-host "NO CREDS ENTERED";pause;return; }
        }
      }catch{ write-host "$($error[0])"; pause; return; }
      <#--------------------------------------------------------------------------------------------
      IGNORE  LIST GET USERS.
      --------------------------------------------------------------------------------------------#>
      if(test-path -path "$($primaryUserEstimator)") {[string[]]$forboden = @(get-content -Path "$($primaryUserEstimator)"); $forboden += "$($creds.username)",$currentPSUserNotFQ,$currentPSuser,"PUBLIC","ADMINISTRATOR","DEFAULT"
        for($v=0;$v-lt($forboden.count);$v++) { $forboden[$v] = $forboden[$v].toupper() }
      }else{ new-item -Path "$($primaryUserEstimator)" -ItemType file | out-null; start-process explorer -erroraction SilentlyContinue -args "$($primaryUserEstimator)"; 
        return "ADD TO IGNORE LIST USERNAMES TO IGNORE WHEN INVOKED ON TARGET PC. NO QUOTES OR COMMAS - 1 PER LINE ('`$env:COMPUTERNAME', 'ADMINISTRATOR', 'PUBLIC' & 'DEFAULT' DIRS WILL BE SKIPPED AUTOMATICALLY)" }
      WRITE-HOST "IGNORELIST:$forboden"
      #foreach($f in $forboden) {write-host ("      $f")} # Import-Module -Name $myModuleFilePath -Verbose. You can add -NoClobber 
      <#---------------------------------------------------------------------------------------------------------------
      GET ONLY ACTIVE CONNECTIONS
      --------------------------------------------------------------------------------------------------------------#>
      write-host "SEPARATING DISCONNECTED PCs"
      $PCNotConnected = @();$activePCList = @()

      try {  $PCNotConnected = @(& $pingEnginePath $pclist) }  # multi-threaded faster option (~40 sec for ~350 PCs)
      catch{ write-host "$($error[0]) [RUNNING REGULAR PING]"
        foreach($pc in $pclist){ try{ Test-connection -computername $pc -count 1 -erroraction stop | out-null} catch {$PCNotConnected += $pc} continue}
      }

      for($i=0;$i-lt$pclist.count;$i++){ if(!($PCNotConnected -contains $pclist[$i])) { $activePCList += $pclist[$i] }}
      if($dev){ write-host "NOT ACCESSIBLE: `r`n ------------------"; foreach($pc in $PCNotConnected) {write-host "$PC"}}
      write-host "CONNECTED: $($activePCList.count) OUT OF $($pclist.count)"
      
      
      if ($null -ne $creds) {                                                                        # preventing runs with no creds (cred prompt was cancelled)
		write-host "RUNNING COMMANDS"																	
<#************************************************************************************************************************************************************
BELOW IS INVOKED ON REMOTE MACHINES
-------------------------------------------------------------------------------------------------------------------------------------------------------------#>
        try { 																						# scriptblock invoked on client as if logged in.
          invoke-command -computername $activePCList -Credential $creds -ScriptBlock {  
            [string]$cacheReset = $using:cacheReset
            [string]$logServerStore = $using:logServerStore
            [string]$stage= $using:stage
           # $admins = $using:admins
            [string]$logServer = $using:logServer
            [string]$logServerPCDir = $using:logServerPCDir
            [string[]]$forboden = $using:forboden
            [string]$domain = $using:domain
            [string]$currentPSuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name   
            [switch]$dev = $using:dev

              <#----------------------------------------------------------------------------------------------
              EXECUTION POLICY SET FOR REMOTE CONNECTION (ALLOWS REFERENCED SCRIPTS TO RUN) NO SCRIPTS REF YET. THEY DONT RUN FOR SOME REASON (2 hop?)
              --------------------------------------------------------------------------------------------------#>
              Set-ExecutionPolicy -ExecutionPolicy bypass -scope CurrentUser -force

            <#---------------------------------------------------------------------------------------------
            CACHE FOLDER 
            ------------------------------------------------------------------------------------------------#>
            $makefolder = (test-path -path $stage)
            if(!($makefolder)) { New-Item -ItemType "directory" -Path $stage | out-null }
            if($cacheReset) { remove-item "$stage\*.csv*" }
            set-location -path $stage

            <#---------------------------------------------------------------------------------------------
            USER APPROX 1st; EXPLORER OWNER: CHEAP WAY TO APPROXIMATE THE ASSIGNEE OF A PC. WORKS IF THEY ARE LOGGED IN
            ------------------------------------------------------------------------------------------------#>
            function getUserByExplorer {
              [string]$userEstExplorerOwner = (Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" |
              ForEach-Object { $_.GetOwner() } | Select-Object -Unique -Expand User) 
              return $userEstExplorerOwner
            }
            <#----------------------------------------------------------------------------------------------
            USER APPROX 2nd; TEMP FOLDER: EXPENSIVE 
            -----------------------------------------------------------------------------------------------#>
            function getUserByTempFolder([switch]$raw,[string[]]$ignorelist,[string]$domain) {<# WILL SELECT WHOEVER RUNS THIS SCRIPT IF INVOKED. SO THAT USER IS ADDED TO IGNORE LIST
            .DESCRIPTION 
            Get users from c:\users. Get mod time of each temp folder. Sort descending. concat username and sorted time together using common indices (creates a ref of the correct order of users | separate parallel arrays = alt to hashtables,objects or jagged arrays)
            reorder names into desc order excluding system and admin users.raw switch will return all users sorted. Without switch you get the top result excluding admins (most likely assignee of the PC)
            .OUTPUTS <string[]>
            #>
              [string[]]$forboden = $ignorelist;  $forboden += (([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).replace("$($domain)\",''));  <# ADDING CURRENT USER TO IGNORE LIST #>
              try{ $userfolders = @(Get-childitem "c:\users\" -Directory | Sort-Object -Property {$_.LastWriteTime} -Descending) # @("ADMINISTRATOR","$($env:COMPUTERNAME)$","PBSENV","ADMIN","SETUP","ADMINISTRATOR.PBSDOM");<#<dependancy>#>
                [string[]]$ulist = @(); [string[]]$uTimes = @(); [string[]]$uListValid = @(); [string[]]$uListPrep = @()
                For($i=0;$i-lt$userfolders.count;$i++) { [string]$n = $userfolders[$i] | select Name; [string]$nn = ($n.replace("@{Name=","")).replace("}",""); $ulist += $nn }
                forEach($u in $ulist){ if(Test-path -Path "c:\users\$($u)\appdata\local\temp") { 
                try{ [string]$temp = (Get-Item -Path "c:\users\$($u)\appdata\local\temp" -erroraction stop | select { $_.LastWriteTime.toString("yyyyMMddhhmm")})
                $t = ($temp.replace('@{ $_.LastWriteTime.toString("yyyyMMddhhmm")=',"")).replace("}","")
                $uTimes += $t; $uListPrep += $u
                }catch{ continue }}}
                $temparr = @($null) * $uListPrep.count; $tempArr2 = @($null) * $uListPrep.count                                                  
                for($i=0;$i-lt$uTimes.count;$i++) { $tempArr[$i] = "$($uTimes[$i])" + "$($uListPrep[$i])" }   
                $uTSorted = $uTimes | sort-object -Descending                                                 
                for($z=0;$z-lt$uTimes.Count;$z++) { for($i=0;$i-lt$uTimes.count;$i++) { if($temparr[$i].contains($uTSorted[$z])) { $tempArr2[$z] = ($tempArr[$i]).replace("$($uTSorted[$z])","") # where the magic happens
                }}}
                [string[]]$tempArr3 = @()
                if(!$raw) { foreach($a in $tempArr2) { if((!($forboden -contains $a.toupper())) -and (!((($a.toUpper())).contains(($env:computername).toupper())))) { $tempArr3 += $a }}
                return $tempArr3[0] }else{ return $tempArr2}
              }catch { write-host "$($error[0])"; return $null }
            }
           <#--------------------------------------------------------------------------------------------------------------------
           USER APPROX 3; PROFILE FOLDER DEPTH(NOT SIZE): LOBSTER PLATE WITH FOOT MASSAGE- OVERKILL. GOES LONG AND PS LIMITS RECURSION 
           TO <100 CALLS WHICH THREW A WRENCH IN THE WHOLE THING. HAVE TO REWRITE. ABANDONED FOR NOW: LEFT OFF: ..\scripts2024\getUserByFolderSize.ps1
           ----------------------------------------------------------------------------------------------------------------------#>
           <#$objUDirs = @(get-ChildItem C:\users -ErrorAction SilentlyContinue)
           [string[]]$udirs = @(get-ChildItem $objUDirs -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
           [int[]]$intSizes,$intSzTmp = @() * ($udirs.count); 
           for($y=0;$y-lt($udirs.count);$y++) {[int]$Sz = Get-ChildItem ($objUserdir[$y].FullName) -erroraction silentlycontinue -recurse | Measure-Object -property length -sum | Select-Object -ExpandProperty Count
           $intSizes += $Sz; 
           }
           for($x=0;$x-lt($udirs.Count);$x++) { 
             for($z=0;$z-lt($uDirs.count);$z++) { 
               if($z -eq (($intSizes.count) - 1)) {                                                             # END OF RANGE CASE
                 if($intSizes[$z] -gt $intSzTmp[$x]) { $intSzTmp[$x] = $intSizes[$z];}
               }elseif($intSizes[$z] -gt $intSizes[$z+1]) { $intSzTmp[$z] = $intSizes[$z+1]; $intSzTmp[$z+1] = $intSizes[$z] 
           } } }  #>                  #LEFT OFF HERE 04/5
           #[pscustomobject]$userFolderSize = @(Get-ChildItem $objUDirs -erroraction silentlycontinue -recurse | Measure-Object -property Length -sum)
           #[int[]]$intUserFolderSize = @(Select-Object -ExpandProperty Count)


          <#-------------------------------------------------------------------------------------------------------
          USER ESTIMATION WEIGHTS/LOGIC
          -------------------------------------------------------------------------------------------------------------#> 
          [string]$passedUserEstimate = ""
          [string]$userEstTempFolder = getUserByTempFolder -ignoreList $forboden -domain $domain
          [string]$userEstExplorerOwner = getUserByExplorer
          if(($userEstExplorerOwner -ne "") -and (!($forboden -contains $userEstExplorerOwner))) { $passedUserEstimate = $userEstExplorerOwner
          }elseif($userEstTempFolder -ne ""){ $passedUserEstimate = $userEstTempFolder
          }else{ $passedUserEstimate = "UNKNOWN" }
          #[string]$passedUserEstimate = $userEstExplorerOwner                       <#HARDSET FOR NOW#>
          <#
          if(($userEstExplorerOwner.toupper()) -ne ($userEstTempFolder.toupper())) {            
          if(($null -ne $userEstExplorerOwner) -and ($userEstExplorerOwner -ne "")) { $passedUserEstimate = $userEstExplorerOwner } # 2nd) Explorer 
          elseif(($null -ne $userEstTempFolder) -and ($userEstTempFolder -ne "")) { $passedUserEstimate = $userEstTempFolder  }  # 3rd) Temp folder
            else{ $passedUserEstimate = "ADMINISTRATOR"}                                        # 4) null case: Hardset to something
          }elseif( $userEstExplorerOwner -ne "" -or $null) { $passedUserEstimate = $userEstExplorerOwner }else{ $passedUserEstimate = "ADMINISTRATOR"}                                   # 1) Match wins
          #>
          # set-location -path "c:\PBSIT"
          #[string[]]$adminsOrSysAccts = "admin","pbsenv","administrator",""
          <#  [string]$passedEstimatedUser = ""
          if(($null -eq $ExplorerOwner) -or ($ExplorerOwner = "")) { 
          $userEstimatorIsPresentInDir = (test-path -path c:\PBSIT\util\PrimaryUserEstimator.ps1)
            if($userEstimatorIsPresentInDir) {
            $userEstimatorArgz = "& .\util\PrimaryUserEstimator.ps1"
            [string]$userEstimateTemp2 = invoke-expression $userEstimatorArgz
          }else{ $passedEstimatedUser = $ExplorerOwner }#>
            <#---------------------------------------------------------------------------------------------
            GET PROGRAMS EXPORT AS HAIRY NAMED CSV
              ------------------------------------------------------------------------------------------------#>
              get-package -Provider Programs -includewindowsinstaller| Select "Name", "Version", "Summary", "CanonicalId", "InstallLocation", "InstallDate", "UninstallString", "QuietUninstallString", "ProductGUID"  | 
              export-csv ("$($stage)\" + (hostname) + "(" + ((& {wmic bios get serialnumber;}) -join "" -replace("SerialNumber","") -replace(" ","")) + ")_$(($passedUserEstimate).toUpper())_" + "-_Apps_-" + ".csv") -notypeinformation -force
     
            
           <#---------------------------------------------------------------------------------------------
           EVENT LOGS
           -----------------------------------------------------------------------------------------------#>
          # log = ("c:\PBSIT\" + $($env:COMPUTERNAME.tostring()) + "(" + ((& {wmic bios get serialnumber;}) -join '' -replace('SerialNumber','') -replace(' ',''))  + "_SysAppLog(-7)" + ((get-date).ToString("yyyyMMdd")) + ".csv")
           if($dev) { 
           write-host "PC: $($env:computername)"
           write-host "PS: $($currentPSUser)"
           write-host "TU: $($userEstTempFolder)"
           write-host "EO: $($userEstExplorerOwner)"
           write-host "PU: $($passedUserEstimate)"
           write-host "----------------------------"
           }
          }      
 <#-------------------------------------------------------------------------------------------------------------------------
 END INVOKE ARGS
 -------------------------------------------------------------------------------------------------------------------------- #>
        }catch{ write-host "$($error[0])"}
      }else{ write-host "CREDENTIAL FAILED"                                                         # abort if bad creds
      break
      }
     <#-------------------------------------------------------------------------------------------------------------------------
     COPY FILES FROM PCs TO LOG LOCATION
     -------------------------------------------------------------------------------------------------------------------------- #>
    write-host "COPYING LOGS TO $logServer"

    [string]$stageRemote = $stage.replace(':','$')
    [string]$logServerPCDirRemote = "$($logServerPCDir.replace(':','$'))"              # SMB path is used for case where script is run on diff server than logserver
    foreach($pc in $activePCList) { 
      [string]$copyLogCommand = "& robocopy `"\\$pc\$stageRemote`" `"\\$($logServer)\$($logServerPCDirRemote)`" `"*$($pc.toupper())*`" /r:0 /w:0 "
      if(($dev) -and ($activePCList[0] -eq $pc)) { write-host "ROBOCOPY ARG USED: $copyLogCommand" }
      invoke-expression $copyLogCommand | out-null
    }

   <# if($PCNotConnected.count -gt 0) {                                                                 # show inaccessible pc names
    write-host ("
    [NOT ACCESSIBLE]
    ")
    $PCNotConnected
    }#>
  }

 <#-------------------------------------------------------------------------------------------------------
 PCListCheck
 .DESCRIPTION 
 CHECKS DefaultPCList PATH. MAKES FILE IF NOT PRESENT
 .OUTPUTS 
 <string[]>
 ----------------------------------------------------------------------------------------------------------#>
  function PCListCheck([string]$defaultPCList) {       
    set-location -path $PSScriptRoot                       
    if (!(test-path -Path $defaultPCList)) { try { New-Item -ItemType file -path $defaultPCList }catch [exception] { write-host "$($error[0])"; break }
    }else{ [string[]]$PCList = @(get-content -path $defaultPCList); if(!($PCList.count -gt 0)){write-host "ADD PCs TO PCLIST AND RERUN"; break }else{ return $PCList}}
  }

 <#-------------------------------------------------------------------------------------------------------
 PCListEdit
 .DESCRIPTION 
 INTERACTIVE. CHECKS DefaultPCList PATH. MAKES FILE IF NOT PRESENT
 .OUTPUTS 
 <string[]>
 ----------------------------------------------------------------------------------------------------------#>
 function PCListEdit {                                              #INTERACTIVE FUNCTION
    set-location -path $PSScriptRoot                                # prep for relative path                             

    if (!(test-path -Path $defaultPCList)) {                        # check list file exists
      try { New-Item -ItemType file -path $defaultPCList }           # make it if missing
	    catch [exception] { write-host "($($error[0])"
      break                                                         # abort on failure
      }
    }
    write-host "[EDIT TARGET LIST] $defaultPCList"                  # tell user why notepad opened
    start-process notepad.exe -wait -ArgumentList $defaultPCList    # open pc list file 
    [string[]]$PCList = @(get-content -path $defaultPCList)                 

    if($PCList.count -lt 1){                                        # require at least 1 pc name
      write-host "[ADD AT LEAST 1 TARGET PC NAME]"
      PCListEdit                                                    # re-call function if less than 1 pc name
    }                         
    return $PCList                                                  # returns names array to caller
  }
  <#----------------------------------------------------------------------------------------------------------------------
  FUNCTION INTERACTIVE 
  -----------------------------------------------------------------------------------------------------------------------#>
  function Interactive {
  [string[]]$pclist = PCListEdit
  inventory1 -pclist $pclist -cacheReset
  }

  <#---------------------------------------------------------------------------------------------
  FUNCTION NON-INTERACTIVE
  ----------------------------------------------------------------------------------------------#>
  function UtilityLoop([int]$run,[string]$info) {
  $LoopTimer = [Diagnostics.Stopwatch]::StartNew()
  if($null -eq $run) { $run = 0 }
  if(($null -eq $global:InvMstStartTime) -or ($run -eq 0)) { [string]$global:InvMstStartTime = "$(Get-Date -format ('yyyy/MM/dd hh:mm'))" }
  [string[]]$pclist = PCListCheck -defaultPCList $defaultPCList
  inventory1 -pclist $pclist -injectInfo $info -cacheReset
  $run++
  [string]$info = "[TIMINGS] RUN:$($run) |LASTRUN(SECONDS):$($LoopTimer.elapsed.totalseconds) | STARTED: $($global:InvMstStartTime)"
  $LoopTimer.stop()
  UtilityLoop -run $run -info $info
  }
  <#---------------------------------------------------------------------------------------------------
  INITIALIZE ARGS 
  ----------------------------------------------------------------------------------------------------#>
  
  if($start -and (!($utility))) { Interactive }elseif($utility -and (!($loop))) { Inventory1 }
  elseif($utility -and $loop) { UtilityLoop }elseif($pclistedit) { PCListEdit; write-host "PCLIST EDITED. RERUN TO USE"}

  }

  